# frozen_string_literal: true

module Routing
  module Analytics
    # Контрфактический реплей истории: что сделал бы наш роутер на тех же
    # ста операциях, которые уже были размаршрутизированы до нас.
    #
    # Это единственный способ сказать про качество роутинга что-то кроме
    # «у нас красивая архитектура». Но честный ответ здесь требует
    # аккуратности, потому что фактический исход известен только для того
    # провайдера, который заявку реально получил:
    #
    #   * совпало с историей — берём фактический исход, это наблюдение;
    #   * разошлось — фактического исхода не существует, и мы НЕ выдаём
    #     желаемое за действительное. Вместо точечной оценки считаем интервал:
    #     нижнюю и верхнюю границы Вильсона по эмпирической конверсии
    #     выбранного провайдера.
    #
    # Поэтому результат — не одно число «стало лучше на X%», а диапазон,
    # внутри которого лежит правда, и доля решений, на которых мы вообще
    # разошлись с историей.
    class Replay
      Result = Struct.new(:decisions, :summary, keyword_init: true)

      def initialize(router:, config:, confidence: 0.95)
        @router = router
        @config = config
        @calibration = router.calibration
        @confidence = confidence
      end

      def run
        rows = @calibration.rows
        raise DataError, "история пуста, реплей невозможен" if rows.empty?

        operations = to_operations(rows)
        fleet = Fleet.new(@router.fleet.providers, issues: @router.issues, zeroed: true)
        router = Router.new(config: @config, fleet: fleet, calibration: @calibration,
                            issues: @router.issues, meta: @router.meta)
        decisions = router.route_all(operations)

        Result.new(decisions: decisions, summary: summarize(rows, decisions, fleet))
      end

      private

      def to_operations(rows)
        rows.each_with_index.map do |row, index|
          Operation.new(id: row[:operation_id] || "hist_#{index}", amount: row[:amount],
                        bank: row[:bank], created_at: row[:created_at], index: index)
        end
      end

      def summarize(rows, decisions, fleet)
        actual = rows.to_h { |row| [row[:operation_id], row] }
        agreed = 0
        matched_approved = 0
        lower = 0.0
        upper = 0.0

        decisions.each do |decision|
          historical = actual[decision.operation.id]
          chosen = decision.selected_provider
          next if historical.nil? || chosen.nil?

          if historical[:provider] == chosen
            agreed += 1
            approved = historical[:status] == Calibration::SUCCESS
            matched_approved += 1 if approved
            lower += approved ? 1.0 : 0.0
            upper += approved ? 1.0 : 0.0
          else
            counts = @calibration.counts_for(chosen)
            if counts[:total].zero?
              # Провайдера нет в истории — оценивать нечем, честно считаем
              # такую операцию неопределённой на всём отрезке 0..1.
              upper += 1.0
            else
              lower += Statistics.wilson_lower_bound(counts[:approved], counts[:total], @confidence)
              upper += wilson_upper_bound(counts[:approved], counts[:total], @confidence)
            end
          end
        end

        total = decisions.size.to_f
        baseline = rows.count { |row| row[:status] == Calibration::SUCCESS }

        {
          "operations" => decisions.size,
          "baseline_approved" => baseline,
          "baseline_approval_rate" => (baseline / total).round(4),
          "agreement_with_history" => agreed,
          "agreement_pct" => (agreed / total * 100).round(1),
          "estimated_approval_rate" => {
            "lower" => (lower / total).round(4),
            "upper" => (upper / total).round(4),
            "note" => "на совпавших решениях взят фактический исход, на разошедшихся — " \
                      "интервал Вильсона по эмпирической конверсии выбранного провайдера"
          },
          "share_comparison" => share_comparison(rows, decisions, fleet),
          "total_variation_distance" => {
            "history_vs_target" => tvd(historical_shares(rows), target_shares(fleet)).round(4),
            "replay_vs_target" => tvd(replay_shares(decisions), target_shares(fleet)).round(4),
            "note" => "суммарное отклонение от целевых долей; меньше — ближе к плану"
          }
        }
      end

      def share_comparison(rows, decisions, fleet)
        history = historical_shares(rows)
        replay = replay_shares(decisions)
        target = target_shares(fleet)

        (history.keys | replay.keys | target.keys).sort.to_h do |id|
          [id, {
            "target_pct" => ((target[id] || 0) * 100).round(1),
            "history_pct" => ((history[id] || 0) * 100).round(1),
            "replay_pct" => ((replay[id] || 0) * 100).round(1)
          }]
        end
      end

      def historical_shares(rows)
        total = rows.size.to_f
        rows.group_by { |row| row[:provider] }.transform_values { |group| group.size / total }
      end

      def replay_shares(decisions)
        total = decisions.size.to_f
        decisions.group_by(&:selected_provider).reject { |id, _| id.nil? }
                 .transform_values { |group| group.size / total }
      end

      def target_shares(fleet)
        fleet.routable.to_h { |provider| [provider.id, fleet.count_target(provider.id)] }
      end

      # Суммарное отклонение распределения от целевого: половина суммы модулей
      # разностей по всем провайдерам. Одно число вместо таблицы отклонений.
      def tvd(actual, target)
        keys = actual.keys | target.keys
        keys.sum { |key| ((actual[key] || 0.0) - (target[key] || 0.0)).abs } / 2.0
      end

      def wilson_upper_bound(successes, trials, confidence)
        return 1.0 if trials.zero?

        z = Statistics.z_for(confidence)
        n = trials.to_f
        phat = successes.to_f / n
        denominator = 1 + ((z**2) / n)
        centre = phat + ((z**2) / (2 * n))
        spread = z * Math.sqrt((phat * (1 - phat) / n) + ((z**2) / (4 * n**2)))
        ((centre + spread) / denominator).clamp(0.0, 1.0)
      end
    end
  end
end
