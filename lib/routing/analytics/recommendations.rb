# frozen_string_literal: true

module Routing
  module Analytics
    # Рекомендации по итогам прогона.
    #
    # Рекомендация вида «стоит улучшить распределение» бесполезна: по ней
    # нечего сделать. Поэтому каждая запись здесь называет конкретный параметр,
    # его текущее значение, предлагаемое и основание в числах. Такую
    # рекомендацию можно применить одной правкой конфигурации и проверить
    # повторным прогоном.
    class Recommendations
      def initialize(decisions:, fleet:, config:, report:, calibration: nil)
        @decisions = decisions
        @fleet = fleet
        @config = config
        @report = report
        @calibration = calibration
        @thresholds = config.section("analytics")
      end

      def build
        items = []
        items.concat(share_drift)
        items.concat(volume_drift)
        items.concat(capacity_pressure)
        items.concat(capacity_efficiency)
        items.concat(conversion_gap)
        items.concat(structural_blocks)
        items.concat(turnover_commitments)
        items.concat(cascade_health)
        items.concat(concentration)
        items.concat(data_gaps)

        limit = @thresholds.fetch("max_recommendations", 12).to_i
        collapse(items)
          .sort_by { |item| [PRIORITY.index(item["priority"]) || 9, -item["impact"].to_f] }
          .first(limit)
      end

      PRIORITY = %w[high medium low].freeze

      private

      # Три одинаковых по смыслу пункта подряд — «у payflow конверсия ниже
      # заявленной», «у quickpay», «у vipay» — читаются как шум и обесценивают
      # весь список. Однотипные рекомендации сливаются в одну: общий вывод и
      # перечисление, у кого именно. Разбор по провайдерам никуда не девается,
      # он уезжает в parts — там его найдёт машина, а человек прочитает вывод.
      GROUP_TEXT = {
        "conversion_24h" => ["Заявленная конверсия расходится с фактической",
                             "обновить conversion_24h: скоринг опирается на числа, которых история не подтверждает"],
        "amount_band" => ["Доли по объёму расходятся с долями по количеству",
                          "заявок партнёры получают ровно свою долю, расходятся размеры чеков: " \
                          "настроить полосы сумм в amount_band"]
      }.freeze

      def collapse(items)
        items.group_by { |item| item["group"] }.flat_map do |group, list|
          next list if group.nil? || list.size < 2 || !GROUP_TEXT.key?(group)

          [merge(group, list)]
        end
      end

      def merge(group, list)
        lead, tail = GROUP_TEXT.fetch(group)
        clauses = list.map { |item| item["short"] }.compact
        best = list.max_by { |item| item["impact"].to_f }

        {
          "text" => "#{lead} у #{list.size} #{plural(list.size, 'партнёра', 'партнёров', 'партнёров')}: " \
                    "#{clauses.join('; ')} — #{tail}",
          "parameter" => list.map { |item| item["parameter"] }.uniq.join(", "),
          "evidence" => list.map { |item| item["evidence"] }.compact.join("; "),
          "priority" => best["priority"],
          "impact" => list.sum { |item| item["impact"].to_f }.round(2),
          "parts" => list.map { |item| item.slice("parameter", "current", "suggested", "evidence") }
        }
      end

      def item(text:, parameter:, priority:, evidence:, current: nil, suggested: nil, impact: 0.0,
               group: nil, short: nil)
        {
          "text" => text, "parameter" => parameter, "current" => current, "suggested" => suggested,
          "evidence" => evidence, "priority" => priority, "impact" => impact.round(2),
          "group" => group, "short" => short
        }.compact
      end

      # 1. Расхождение факта с целевой долей.
      def share_drift
        threshold = @thresholds.fetch("share_drift_alert_pct", 10.0).to_f
        @report.distribution.filter_map do |id, row|
          next if @fleet.provider_for(id)&.self_provider?

          deviation = row["deviation_pct"].to_f
          next if deviation.abs < threshold

          direction = deviation.negative? ? "недобирает" : "перебирает"
          suggested = (row["target_pct"].to_f + (deviation / 2.0)).round(1)
          item(
            text: "#{id} #{direction} долю: факт #{row['share_pct']}% против цели #{row['target_pct']}% " \
                  "(отклонение #{deviation.round(1)} п.п.) — привести traffic_percentage к #{suggested}% " \
                  "или снять ограничение, из-за которого он выпадает",
            parameter: "providers.#{id}.traffic_percentage",
            current: row["target_pct"], suggested: suggested,
            evidence: "#{row['count']} из #{@decisions.size} операций",
            priority: deviation.abs >= threshold * 2 ? "high" : "medium",
            impact: deviation.abs
          )
        end
      end

      # 1б. Расхождение по объёму. Считается отдельно от количества намеренно:
      # это разные цели, и расходятся они по разным причинам. Провайдер может
      # получать ровно свою долю заявок и при этом вдвое перебирать по деньгам —
      # достаточно, чтобы ему доставались крупные чеки.
      def volume_drift
        threshold = @thresholds.fetch("share_drift_alert_pct", 10.0).to_f
        @report.distribution.filter_map do |id, row|
          next if @fleet.provider_for(id)&.self_provider?

          deviation = row["volume_deviation_pct"].to_f
          next if deviation.abs < threshold
          # Если по количеству всё сходится, а по объёму нет — дело в размере
          # чеков, и менять надо полосы сумм, а не долю трафика.
          count_ok = row["deviation_pct"].to_f.abs < threshold
          parameter = count_ok ? "strategies.amount_band.bands" : "providers.#{id}.volume_share_pct"

          item(
            text: "#{id} #{deviation.negative? ? 'недобирает' : 'перебирает'} по объёму: " \
                  "факт #{row[%q(volume_share_pct)]}% против цели #{row[%q(target_volume_pct)]}% " \
                  "(#{deviation.round(1).abs} п.п. #{deviation.negative? ? %q(ниже) : %q(выше)}) при доле по количеству #{row[%q(share_pct)]}% — " \
                  "#{count_ok ? 'заявок он получает ровно свою долю, расходятся размеры чеков: настроить полосы сумм в amount_band' : "привести volume_share_pct к #{(row['volume_share_pct'].to_f).round(1)}% или пересмотреть долю по количеству"}",
            parameter: parameter,
            current: row["target_volume_pct"], suggested: count_ok ? nil : row["volume_share_pct"],
            evidence: "объём #{row['volume']} из общего по прогону",
            priority: deviation.abs >= threshold * 2 ? "medium" : "low",
            impact: deviation.abs,
            group: count_ok ? "amount_band" : nil,
            short: "#{id} #{deviation.negative? ? 'недобирает' : 'перебирает'} #{deviation.abs.round(1)} п.п."
          )
        end
      end

      # 2. Давление на лимиты.
      def capacity_pressure
        threshold = @thresholds.fetch("utilization_alert_pct", 80.0).to_f
        @fleet.providers.filter_map do |provider|
          state = @fleet[provider.id]
          utilization = state.daily_utilization * 100
          next if utilization < threshold || provider.daily_amount_limit.nil?

          headroom = state.headroom_amount
          share = @fleet.count_target(provider.id) * 100
          # Предлагаем не «долю, пропорциональную остатку лимита» — на исчерпанном
          # лимите это выродилось бы в 0.1% и было бы бесполезным советом, — а
          # доказанный потолок достижимости: столько заявок провайдер реально вмещает.
          ceiling = achievable_ceiling(provider.id)
          suggested = (ceiling || (share * (1 - (utilization / 100.0)))).round(1)
          basis = ceiling ? "это доказанный потолок по свободному лимиту" : "пропорционально остатку лимита"
          item(
            text: "#{provider.id} выбрал #{utilization.round(1)}% дневного лимита, свободно #{headroom} — " \
                  "снизить traffic_percentage с #{share.round(1)}% до #{suggested}% (#{basis}) " \
                  "или поднять daily_amount_limit, иначе он выпадет из распределения до конца суток",
            parameter: "providers.#{provider.id}.traffic_percentage",
            current: share.round(1), suggested: suggested,
            evidence: "оборот #{state.daily_amount} при лимите #{provider.daily_amount_limit}",
            priority: utilization >= 95 ? "high" : "medium",
            impact: utilization
          )
        end
      end

      # 3. Заявленная конверсия против наблюдаемой.
      # Лимит в деньгах, цель в заявках.
      #
      # Партнёр может выбрать дневной лимит целиком и всё равно недобрать свою
      # долю — если ему достались крупные чеки. Те же деньги, потраченные на
      # мелкие выплаты, дали бы больше заявок. Разрыв виден точно: потолок по
      # ёмкости в разделе достижимости считается жадным набором самых дешёвых
      # заявок в пределах свободного лимита, и если факт ниже потолка, значит
      # деньги ушли на чеки крупнее, чем следовало.
      #
      # Это не абстракция: на прогоне из шестидесяти заявок payflow забрал семь
      # штук на 99 300 ₽ при потолке в одиннадцать.
      CAPACITY_EFFICIENCY_GAP_PCT = 2.0

      def capacity_efficiency
        total = @report.distribution.sum { |_, row| row["count"].to_i }
        return [] if total.zero?

        @fleet.providers.filter_map do |provider|
          next if provider.self_provider? || provider.daily_amount_limit.nil?

          state = @fleet[provider.id]
          next if (state.daily_utilization * 100) < 95.0

          row = @report.distribution[provider.id]
          ceiling = achievable_ceiling(provider.id)
          next if row.nil? || ceiling.nil?

          gap = ceiling.to_f - row["share_pct"].to_f
          next if gap < CAPACITY_EFFICIENCY_GAP_PCT

          count = row["count"].to_i
          fits = (ceiling.to_f * total / 100.0).round
          average = count.positive? ? (row["volume"].to_f / count).round : 0

          item(
            text: "#{provider.id} исчерпал дневной лимит на #{count} " \
                  "#{plural(count, 'заявке', 'заявках', 'заявках')} при среднем чеке #{average} — " \
                  "теми же деньгами он вместил бы #{fits}: его потолок по ёмкости #{ceiling}% " \
                  "против фактических #{row['share_pct']}%. Лимит задан в деньгах, а доля в заявках, " \
                  "поэтому крупные выплаты стоят ему собственной доли: сузить верхнюю границу чека " \
                  "или отдать ему полосу мелких сумм",
            parameter: "providers.#{provider.id}.limit_amount_max",
            current: provider.limit_amount_max&.to_major,
            evidence: "#{count} заявок на #{row['volume']} при свободном лимите на #{fits}",
            priority: "high",
            impact: gap
          )
        end
      end

      def conversion_gap
        return [] if @calibration.nil? || @calibration.empty?

        alert = @thresholds.fetch("conversion_alert", 0.6).to_f
        @fleet.providers.filter_map do |provider|
          observed = @calibration.success_rate_for(provider.id)
          declared = provider.conversion_24h
          next if observed.nil? || declared.nil?

          gap = observed - declared
          next if gap.abs < 0.05

          counts = @calibration.counts_for(provider.id)
          lower = @calibration.conservative_rate_for(provider.id)
          item(
            text: "у #{provider.id} заявленная конверсия #{(declared * 100).round(1)}%, по истории " \
                  "#{(observed * 100).round(1)}% на #{counts[:total]} операциях " \
                  "(нижняя граница #{(lower * 100).round(1)}%) — обновить conversion_24h, " \
                  "иначе скоринг систематически #{gap.negative? ? 'переоценивает' : 'недооценивает'} его",
            parameter: "providers.#{provider.id}.conversion_24h",
            current: declared, suggested: observed.round(3),
            evidence: "#{counts[:approved]} одобрено из #{counts[:total]}",
            priority: (observed < alert || gap.abs >= 0.15) ? "high" : "medium",
            impact: gap.abs * 100,
            group: "conversion_24h",
            short: "#{provider.id} #{(declared * 100).round}% против #{(observed * 100).round}% " \
                   "на #{counts[:total]}"
          )
        end
      end

      # 4. Структурные блокировки: цель недостижима не из-за перекоса, а потому
      # что провайдера раз за разом отсекает одно и то же жёсткое ограничение.
      def structural_blocks
        counts = Hash.new { |hash, key| hash[key] = Hash.new(0) }
        @decisions.each do |decision|
          decision.attempts.each do |attempt|
            next unless attempt["decision"] == "skipped"
            next unless Reasons.category(attempt["reason"]) == :hard

            counts[attempt["provider"]][attempt["reason"]] += 1
          end
        end

        counts.filter_map do |provider_id, reasons|
          reason, count = reasons.max_by { |_, value| value }
          next if count < (@decisions.size / 3.0)

          provider = @fleet.provider_for(provider_id)
          next if provider.nil? || provider.self_provider?
          # Провайдеру, у которого кончается дневной лимит, бессмысленно советовать
          # расширить банковский список: иначе отчёт одновременно просит снизить его
          # долю и дать ему больше заявок.
          next if @fleet[provider_id].daily_utilization * 100 >=
                  @thresholds.fetch("utilization_alert_pct", 80.0).to_f

          item(
            text: "#{provider_id} отсеян #{count} #{plural(count, 'раз', 'раза', 'раз')} из #{@decisions.size} по причине «#{Reasons.text(reason)}» — " \
                  "#{fix_for(reason, provider)}",
            parameter: parameter_for(reason, provider_id),
            evidence: "доминирующая причина отсева #{reason}",
            priority: count >= @decisions.size / 2.0 ? "high" : "medium",
            impact: count * 10
          )
        end
      end

      # 5. Финансовые обязательства по обороту.
      def turnover_commitments
        @fleet.providers.filter_map do |provider|
          gap = @fleet[provider.id].turnover_min_gap
          next if gap.nil? || gap.zero?

          item(
            text: "#{provider.id} не добрал #{gap} до обязательства daily_turnover_min " \
                  "#{provider.daily_turnover_min} — поднять его вес в turnover_commitment " \
                  "или пересмотреть обязательство",
            parameter: "strategies.turnover_commitment.weight",
            current: @config.fetch("strategies", "turnover_commitment", "weight"),
            suggested: ((@config.fetch("strategies", "turnover_commitment", "weight", default: 1.2).to_f) * 1.5).round(2),
            evidence: "оборот #{@fleet[provider.id].daily_amount} при обязательстве #{provider.daily_turnover_min}",
            priority: "medium",
            impact: gap.to_major.to_f / 1000.0
          )
        end
      end

      # 6. Здоровье каскада.
      def cascade_health
        stats = @report.cascade_stats
        outcomes = @report.outcomes
        items = []

        if outcomes["approval_rate"].to_f < @thresholds.fetch("conversion_alert", 0.6).to_f
          items << item(
            text: "доля одобренных #{(outcomes['approval_rate'].to_f * 100).round(1)}% — " \
                  "поднять вес конверсии или перейти на профиль conversion_first",
            parameter: "strategies.conversion.weight",
            current: @config.fetch("strategies", "conversion", "weight"),
            suggested: ((@config.fetch("strategies", "conversion", "weight", default: 1.0).to_f) * 1.5).round(2),
            evidence: "#{outcomes['approved']} одобрено из #{@decisions.size}",
            priority: "high", impact: 100 - (outcomes["approval_rate"].to_f * 100)
          )
        end

        if stats["fallback_used"].to_i.positive?
          items << item(
            text: "fallback на собственного провайдера сработал #{stats['fallback_used']} раз — " \
                  "расширить пул внешних провайдеров под эти заявки, " \
                  "каждое такое срабатывание означает, что маршрута не нашлось",
            parameter: "run.max_attempts",
            current: @config.fetch("run", "max_attempts"),
            evidence: "средняя глубина каскада #{stats['avg_depth']}",
            priority: "high", impact: stats["fallback_used"].to_i * 20
          )
        end

        items
      end

      # 7. Концентрация трафика.
      def concentration
        shares = @report.distribution.reject { |id, _| @fleet.provider_for(id)&.self_provider? }
                        .transform_values { |row| row["share_pct"].to_f }
        return [] if shares.empty?

        hhi = Statistics.concentration(shares.values)
        even = 1.0 / shares.size
        return [] if hhi < (even * 1.8)

        leader = shares.max_by { |_, value| value }
        [item(
          text: "трафик сконцентрирован: индекс #{hhi.round(2)} при равномерном #{even.round(2)}, " \
                "#{leader.first} забирает #{leader.last.round(1)}% — уменьшить tier_epsilon " \
                "или поднять вес count_share, чтобы распределение выравнивалось быстрее",
          parameter: "scoring.tier_epsilon",
          current: @config.fetch("scoring", "tier_epsilon"),
          suggested: ((@config.fetch("scoring", "tier_epsilon", default: 0.05).to_f) / 2).round(3),
          evidence: "индекс Херфиндаля–Хиршмана #{hhi.round(3)}",
          priority: "medium", impact: hhi * 100
        )]
      end

      # 8. Дыры во входных данных.
      def data_gaps
        missing = @fleet.routable.reject { |provider| provider.volume_share_pct }
        return [] if missing.empty?

        [item(
          text: "у #{missing.map(&:id).join(', ')} не задан volume_share_pct — цель по объёму " \
                "считается по доле количества, что для разных по размеру чеков даёт разный результат",
          parameter: "providers.*.volume_share_pct",
          evidence: "поле отсутствует у #{missing.size} из #{@fleet.routable.size} провайдеров",
          priority: "low", impact: 5
        )]
      end

      # Русская форма числительного: 1 раз, 2 раза, 5 раз.
      # Мелочь, но текст рекомендации читают люди, и «отсеян 4 раз» бросается
      # в глаза сильнее, чем стоит любая экономия на такой функции.
      def plural(count, one, few, many)
        tail = count.abs % 100
        return many if (11..14).cover?(tail)

        case tail % 10
        when 1 then one
        when 2, 3, 4 then few
        else many
        end
      end

      # Потолок из анализа достижимости, если он посчитан.
      def achievable_ceiling(provider_id)
        bounds = @report.target_achievability&.dig("bounds", provider_id)
        bounds && bounds["ceiling_pct"]
      end

      def fix_for(reason, provider)
        case reason
        when "bank_not_in_list", "bank_excluded", "bank_unknown"
          "расширить banks или снять фильтр, сейчас список: #{provider.banks.join(', ')}"
        when "amount_exceeds_limit"
          "поднять limit_amount_max, сейчас #{provider.limit_amount_max}"
        when "amount_below_minimum"
          "снизить limit_amount_min, сейчас #{provider.limit_amount_min}"
        when "daily_limit_exceeded"
          "поднять daily_amount_limit или перераспределить долю на других"
        when "no_available_requisites"
          "добавить реквизиты: пул исчерпан"
        when "rate_limit_exceeded"
          "поднять requests_per_minute_limit"
        when "zero_traffic_share"
          "выделить долю трафика, иначе провайдер не участвует в распределении"
        else
          "проверить настройку провайдера"
        end
      end

      def parameter_for(reason, provider_id)
        field = case reason
                when "bank_not_in_list", "bank_excluded", "bank_unknown" then "banks"
                when "amount_exceeds_limit" then "limit_amount_max"
                when "amount_below_minimum" then "limit_amount_min"
                when "daily_limit_exceeded" then "daily_amount_limit"
                when "no_available_requisites" then "available_requisites"
                when "rate_limit_exceeded" then "requests_per_minute_limit"
                when "zero_traffic_share" then "traffic_percentage"
                else "status"
                end
        "providers.#{provider_id}.#{field}"
      end
    end
  end
end
