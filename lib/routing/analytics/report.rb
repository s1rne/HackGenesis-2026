# frozen_string_literal: true

module Routing
  module Analytics
    # Итоговая аналитика прогона — то, что уезжает в routing_report.json.
    #
    # Обязательный минимум задан организаторами: period, total_operations,
    # distribution, skip_reasons, projected_daily_utilization, recommendations.
    # К нему добавлено то, без чего по распределению нельзя сделать ни одного
    # вывода: отклонение факта от цели, исходы и конверсия по провайдерам,
    # глубина каскада, уступки по недостижимым целям и качество входных данных.
    class Report
      def initialize(decisions:, fleet:, config:, period:, calibration: nil, issues: nil, meta: {}, describe: {})
        @decisions = decisions
        @fleet = fleet
        @config = config
        @period = period
        @calibration = calibration
        @issues = issues
        @meta = meta || {}
        @describe = describe || {}
        @thresholds = config.section("analytics")
      end

      def to_h
        {
          "period" => @period,
          "total_operations" => @decisions.size,
          "distribution" => distribution,
          "skip_reasons" => skip_reasons,
          "projected_daily_utilization" => projected_daily_utilization,
          "recommendations" => recommendations.map { |r| r["text"] },
          "outcomes" => outcomes,
          "provider_performance" => provider_performance,
          "cascade" => cascade_stats,
          "goal_relaxations" => goal_relaxations,
          "limits_at_risk" => limits_at_risk,
          "history_baseline" => history_baseline,
          "recommendations_detailed" => recommendations,
          "routing_setup" => @describe,
          "data_quality" => data_quality,
          "source" => @meta
        }.compact
      end

      # --- обязательные разделы ------------------------------------------------

      # Факт против цели по каждому провайдеру. Само по себе «vipay получил 20%»
      # ничего не значит — значение появляется только рядом с целью и отклонением.
      def distribution
        total = @decisions.size
        total_amount = selected_amount_total

        @fleet.providers.to_h do |provider|
          id = provider.id
          count = selected_count(id)
          amount = selected_amount(id)
          target = @fleet.count_target(id) * 100
          volume_target = @fleet.volume_target(id) * 100
          share = total.zero? ? 0.0 : (count.to_f / total * 100)
          volume_share = total_amount.zero? ? 0.0 : (amount.to_f / total_amount * 100)

          [id, {
            "count" => count,
            "share_pct" => share.round(1),
            "target_pct" => target.round(1),
            "deviation_pct" => (share - target).round(1),
            "volume" => amount.round(2),
            "volume_share_pct" => volume_share.round(1),
            "target_volume_pct" => volume_target.round(1),
            "volume_deviation_pct" => (volume_share - volume_target).round(1)
          }]
        end
      end

      # Сколько раз каждая причина отсева сработала. Ключи — машинные коды
      # из каталога причин, поэтому агрегат всегда сходится с attempts.
      def skip_reasons
        counts = Hash.new(0)
        each_attempt { |attempt| counts[attempt["reason"]] += 1 if attempt["decision"] == "skipped" }
        counts.sort_by { |reason, count| [-count, reason] }.to_h
      end

      def projected_daily_utilization
        @fleet.providers.to_h do |provider|
          state = @fleet[provider.id]
          limit = provider.daily_amount_limit
          entry = {
            "used" => state.daily_amount.as_json,
            "limit" => limit&.as_json,
            "utilization_pct" => (state.daily_utilization * 100).round(1),
            "headroom" => state.headroom_amount&.as_json,
            "added_this_run" => (state.daily_amount - (provider.initial_daily_amount || Money.zero)).as_json
          }
          if provider.daily_turnover_min
            entry["turnover_min"] = provider.daily_turnover_min.as_json
            entry["turnover_min_gap"] = state.turnover_min_gap&.as_json
            entry["turnover_min_met"] = state.turnover_min_gap.nil? || state.turnover_min_gap.zero?
          end
          [provider.id, entry.compact]
        end
      end

      # --- дополнительные разделы ---------------------------------------------

      def outcomes
        counts = @decisions.group_by(&:simulated_result).transform_values(&:size)
        approved = counts["approved"].to_i
        {
          "approved" => approved,
          "rejected" => counts["rejected"].to_i,
          "expired" => counts["expired"].to_i,
          "approval_rate" => @decisions.empty? ? 0.0 : (approved.to_f / @decisions.size).round(4),
          "avg_latency_sec" => average(@decisions.map(&:latency_sec)),
          "total_latency_sec" => @decisions.sum(&:latency_sec)
        }
      end

      def provider_performance
        @fleet.providers.to_h do |provider|
          state = @fleet[provider.id]
          declared = provider.conversion_24h
          observed = state.observed_conversion
          [provider.id, {
            "attempts" => state.attempt_count,
            "selected" => state.selected_count,
            "approved" => state.approved_count,
            "declined" => state.declined_count,
            "expired" => state.expired_count,
            "skipped" => state.skipped_count,
            "declared_conversion" => declared,
            "observed_conversion" => observed&.round(4),
            "conversion_gap" => (observed && declared) ? (observed - declared).round(4) : nil,
            "load_factor" => state.load_factor.round(4),
            "available_requisites" => state.available_requisites
          }.compact]
        end
      end

      # Каскад имеет смысл мерить не «сколько раз сработал», а «сколько
      # одобрений он вытащил»: доля операций, принятых не с первой попытки, —
      # это и есть польза от перехода к следующему провайдеру.
      def cascade_stats
        depths = @decisions.map { |d| d.cascade_path.size }
        rescued = @decisions.count { |d| d.approved? && d.cascade_path.size > 1 }
        fallbacks = @decisions.count { |d| d.cascade_path.any? { |step| step["fallback"] } }
        {
          "avg_depth" => average(depths),
          "max_depth" => depths.max.to_i,
          "single_attempt" => depths.count { |d| d <= 1 },
          "multi_attempt" => depths.count { |d| d > 1 },
          "rescued_by_cascade" => rescued,
          "cascade_uplift_pct" => @decisions.empty? ? 0.0 : (rescued.to_f / @decisions.size * 100).round(1),
          "fallback_used" => fallbacks
        }
      end

      def goal_relaxations
        events = @decisions.flat_map { |d| d.events.map { |e| e.merge("operation_id" => d.operation.id) } }
        return [] if events.empty?

        events
      end

      # Провайдеры, у которых что-то вот-вот упрётся в потолок. Это самая
      # практичная часть отчёта: она отвечает на вопрос «что сломается завтра».
      def limits_at_risk
        threshold = @thresholds.fetch("utilization_alert_pct", 80.0).to_f / 100.0
        @fleet.providers.filter_map do |provider|
          state = @fleet[provider.id]
          measures = {
            "дневной оборот" => state.daily_utilization,
            "заявки в работе" => state.in_progress_count_utilization,
            "сумма в работе" => state.in_progress_amount_utilization,
            "реквизиты" => state.requisite_utilization
          }.select { |_, value| value >= threshold }
          next if measures.empty?

          {
            "provider" => provider.id,
            "measures" => measures.transform_values { |v| (v * 100).round(1) },
            "worst" => measures.max_by { |_, v| v }.first
          }
        end
      end

      def history_baseline
        return nil if @calibration.nil? || @calibration.empty?

        {
          "operations" => @calibration.size,
          "providers" => @calibration.summary(@config.fetch("strategies", "conversion", "confidence", default: 0.95))
        }
      end

      def data_quality
        return nil if @issues.nil? || @issues.empty?

        {
          "counts" => @issues.count_by_severity.transform_keys(&:to_s),
          "items" => @issues.as_json.map { |item| item.transform_keys(&:to_s).transform_values(&:to_s) }
        }
      end

      def recommendations
        @recommendations ||= Recommendations.new(
          decisions: @decisions, fleet: @fleet, config: @config,
          calibration: @calibration, report: self
        ).build
      end

      private

      def each_attempt
        @decisions.each { |decision| decision.attempts.each { |attempt| yield(attempt) } }
      end

      def selected_count(id) = @decisions.count { |d| d.selected_provider == id }

      def selected_amount(id)
        @decisions.select { |d| d.selected_provider == id }.sum { |d| d.operation.amount.to_major.to_f }
      end

      def selected_amount_total = @decisions.sum { |d| d.operation.amount.to_major.to_f }

      def average(values)
        return 0.0 if values.nil? || values.empty?

        (values.sum.to_f / values.size).round(2)
      end
    end
  end
end
