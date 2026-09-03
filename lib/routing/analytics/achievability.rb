# frozen_string_literal: true

module Routing
  module Analytics
    # Достижимость целевых долей.
    #
    # Отклонение факта от цели можно объяснить двумя совершенно разными
    # причинами, и путать их нельзя:
    #
    #   * политика распределяет плохо — это чинится настройками;
    #   * цель недостижима в принципе — никакая политика не поможет,
    #     чинится только пересмотром лимитов, банковских списков или самой цели.
    #
    # Здесь считается второе, и считается строго, без моделирования. Для набора
    # заявок и структурных ограничений (статус, диапазон суммы, банк, маржа,
    # валюта — всё, что не зависит от текущей загрузки) выводятся две границы:
    #
    #   потолок    — доля заявок, которые провайдер вообще имеет право взять;
    #   пол        — доля заявок, где он единственный, кто имеет право.
    #
    # Если цель выше потолка или ниже пола, она недостижима — и это
    # доказывается пересчётом, а не обсуждается.
    class Achievability
      Bound = Struct.new(:provider, :target, :floor, :ceiling, :capacity_ceiling, :binding_limit,
                         :verdict, :blocking_reasons, keyword_init: true)

      def initialize(fleet:, constraints:, config:)
        @fleet = fleet
        @config = config
        # Только структурные правила: загрузка меняется по ходу прогона,
        # и включать её сюда значило бы измерять политику, а не структуру.
        @constraints = constraints.reject { |constraint| constraint.class.stateful? }
      end

      def analyse(operations)
        eligibility = operations.map { |operation| eligible_ids(operation) }
        total = operations.size.to_f
        return { "operations" => 0, "bounds" => {}, "unroutable" => 0 } if total.zero?

        forced = Hash.new(0)
        capacity = Hash.new(0)
        unroutable = 0

        eligibility.each do |ids|
          unroutable += 1 if ids.empty?
          ids.each { |id| capacity[id] += 1 }
          forced[ids.first] += 1 if ids.size == 1
        end

        eligible_by_provider = Hash.new { |hash, key| hash[key] = [] }
        operations.each_with_index do |operation, index|
          eligibility[index].each { |id| eligible_by_provider[id] << operation }
        end

        bounds = @fleet.routable.map do |provider|
          build_bound(provider,
                      forced[provider.id] / total,
                      capacity[provider.id] / total,
                      capacity_ceiling(provider, eligible_by_provider[provider.id]) / total,
                      operations)
        end

        {
          "operations" => operations.size,
          "unroutable" => unroutable,
          "structural_constraints" => @constraints.map(&:id),
          "bounds" => bounds.to_h { |bound| [bound.provider, bound_to_h(bound)] },
          "verdict" => overall_verdict(bounds),
          "min_total_variation_distance" => combined_floor(bounds, operations).round(4),
          "floors" => floors(bounds, operations),
          "assumption" => "коридоры и минимальное отклонение верны в предположении, что каждая " \
                          "заявка уходит допустимому внешнему провайдеру. При политике " \
                          "exhausted_pool_policy: fallback часть заявок уходит на self-провайдера, " \
                          "и доли внешних могут опуститься ниже пола — это другая постановка задачи, " \
                          "а не противоречие"
        }
      end

      private

      def eligible_ids(operation)
        @fleet.routable.filter_map do |provider|
          context = EvaluationContext.new(
            operation: operation, provider: provider, state: @fleet[provider.id],
            fleet: @fleet, at: operation.created_at&.to_f || Float::INFINITY,
            config: @config, attempt_no: 1, excluded: []
          )
          provider.id if @constraints.none? { |constraint| constraint.check(context) }
        end
      end

      def build_bound(provider, floor, structural_ceiling, capacity_ceiling, operations)
        target = @fleet.count_target(provider.id)
        ceiling = [structural_ceiling, capacity_ceiling].min
        binding_limit = capacity_ceiling < structural_ceiling ? "дневной лимит оборота" : "структурные ограничения"

        verdict = if target > ceiling + 1e-9
                    "недостижима сверху"
                  elsif target < floor - 1e-9
                    "недостижима снизу"
                  else
                    "достижима"
                  end

        Bound.new(provider: provider.id, target: target, floor: floor, ceiling: ceiling,
                  capacity_ceiling: capacity_ceiling, binding_limit: binding_limit, verdict: verdict,
                  blocking_reasons: verdict == "недостижима сверху" ? blocking_reasons(provider, operations) : {})
      end

      # Сколько заявок из этой очереди провайдер способен принять по деньгам.
      #
      # Структурные ограничения говорят, какие заявки он имеет ПРАВО взять;
      # свободный дневной лимит — сколько он их ФИЗИЧЕСКИ вместит. Берём самые
      # дешёвые из допустимых, пока хватает остатка: это и есть максимум по числу
      # операций, больше не получится ни при какой стратегии.
      #
      # Именно здесь чаще всего и ломается цель по доле: провайдер проходит все
      # фильтры, но у него осталось денег на две заявки из десяти.
      # Свободный лимит НА НАЧАЛО прогона, а не на конец.
      #
      # Брать текущее состояние здесь нельзя: к моменту сборки отчёта провайдер
      # уже потратил часть лимита на те самые заявки, вместимость которых мы
      # считаем. Получилась бы бессмыслица — «максимум три заявки» при фактически
      # обработанных трёх и нулевом остатке, то есть потолок ниже факта.
      def initial_headroom(provider)
        caps = [provider.daily_amount_limit, provider.daily_turnover_max].compact
        return nil if caps.empty?

        remaining = caps.min - (provider.initial_daily_amount || Money.zero)
        remaining.negative? ? Money.zero : remaining
      end

      def capacity_ceiling(provider, eligible_operations)
        headroom = initial_headroom(provider)
        return eligible_operations.size.to_f if headroom.nil?

        spent = Money.zero
        eligible_operations.map(&:amount).sort.count do |amount|
          next false if spent + amount > headroom

          spent += amount
          true
        end.to_f
      end

      # Чем именно провайдера отсекает: агрегат причин по всем заявкам,
      # которые он не имеет права взять. Это и есть ответ на вопрос
      # «что поменять, чтобы цель стала достижимой».
      def blocking_reasons(provider, operations)
        counts = Hash.new(0)
        operations.each do |operation|
          context = EvaluationContext.new(
            operation: operation, provider: provider, state: @fleet[provider.id],
            fleet: @fleet, at: operation.created_at&.to_f || Float::INFINITY,
            config: @config, attempt_no: 1, excluded: []
          )
          violation = @constraints.filter_map { |constraint| constraint.check(context) }.first
          counts[violation.reason] += 1 if violation
        end
        counts.sort_by { |_, count| -count }.to_h
      end

      def bound_to_h(bound)
        {
          "target_pct" => (bound.target * 100).round(1),
          "floor_pct" => (bound.floor * 100).round(1),
          "ceiling_pct" => (bound.ceiling * 100).round(1),
          "capacity_ceiling_pct" => (bound.capacity_ceiling * 100).round(1),
          "binding_limit" => bound.binding_limit,
          "verdict" => bound.verdict,
          "blocking_reasons" => bound.blocking_reasons.empty? ? nil : bound.blocking_reasons
        }.compact
      end

      def overall_verdict(bounds)
        broken = bounds.reject { |bound| bound.verdict == "достижима" }
        return "целевое распределение достижимо структурными ограничениями" if broken.empty?

        broken.map do |bound|
          "цель #{(bound.target * 100).round(1)}% на #{bound.provider} #{bound.verdict}: " \
            "коридор #{(bound.floor * 100).round(1)}..#{(bound.ceiling * 100).round(1)}%, " \
            "ограничивает — #{bound.binding_limit}" \
            "#{bound.blocking_reasons.empty? ? '' : ", причина — #{bound.blocking_reasons.keys.first}"}"
        end.join("; ")
      end

      # Минимально возможное отклонение от целей: каждая цель подтягивается
      # к своему коридору, остаток отклонения уже неустраним.
      # Три независимых способа посчитать, насколько близко к плану вообще можно
      # подойти. Совпадение трёх ответов, полученных по-разному, — куда более
      # сильное утверждение, чем один расчёт.
      def floors(bounds, operations)
        rounding = rounding_floor(operations.size)
        structural = min_tvd(bounds)
        exact = exact_optimum(operations)

        {
          "rounding_pct" => (rounding * 100).round(2),
          "structural_pct" => (structural * 100).round(2),
          "exact_pct" => exact && (exact * 100).round(2),
          "note" => "нижняя граница отклонения от целевых долей, три расчёта. " \
                    "«Округление» — сколько остаётся из-за того, что заявка неделима: " \
                    "доля 35% от #{operations.size} заявок это #{(0.35 * operations.size).round(2)} заявки, " \
                    "а половину выплаты отправить нельзя. «Структура» — сколько остаётся из-за " \
                    "банковских списков, диапазонов сумм и дневных лимитов. «Перебор» — точный " \
                    "минимум по всем допустимым раскладкам, считается когда их обозримо мало."
        }.compact
      end

      def combined_floor(bounds, operations)
        exact = exact_optimum(operations)
        return exact if exact

        [rounding_floor(operations.size), min_tvd(bounds)].max
      end

      # Отклонение, которое остаётся при идеальном распределении, если забыть про
      # все ограничения и помнить только, что заявка неделима.
      #
      # Метод наибольших остатков для этой задачи оптимален: он минимизирует сумму
      # модулей отклонений при целых числах, дающих в сумме N. Поэтому полученное
      # им значение — не оценка, а точная нижняя граница.
      def rounding_floor(total)
        return 0.0 if total.zero?

        targets = @fleet.routable.to_h { |provider| [provider.id, @fleet.count_target(provider.id)] }
        return 0.0 if targets.values.sum <= 0

        counts = Statistics.largest_remainder(targets, total)
        targets.sum { |id, share| ((counts[id].to_f / total) - share).abs } / 2.0
      end

      # Точный минимум перебором всех допустимых раскладок.
      #
      # На десяти заявках вариантов меньше сотни, и перебор отвечает на вопрос
      # окончательно: не «граница не ниже», а «вот столько, и вот такая раскладка».
      # На больших очередях перебор невозможен, и тогда мы честно возвращаем nil,
      # оставляя две аналитические границы.
      MAX_ENUMERATION = 500_000

      def exact_optimum(operations)
        choices = operations.map { |operation| eligible_ids(operation) }
        return nil if choices.any?(&:empty?)

        space = choices.reduce(1) { |acc, list| acc * list.size }
        return nil if space > MAX_ENUMERATION || space <= 0

        targets = @fleet.routable.to_h { |provider| [provider.id, @fleet.count_target(provider.id)] }
        headroom = @fleet.routable.to_h { |provider| [provider.id, initial_headroom(provider)] }
        total = operations.size.to_f
        best = nil

        choices.first.product(*choices[1..]) do |combo|
          counts = Hash.new(0)
          spent = Hash.new { |hash, key| hash[key] = Money.zero }
          combo.each_with_index do |id, index|
            counts[id] += 1
            spent[id] += operations[index].amount
          end
          next if headroom.any? { |id, room| room && spent[id] > room }

          deviation = targets.sum { |id, share| ((counts[id].to_f / total) - share).abs } / 2.0
          best = deviation if best.nil? || deviation < best
        end

        best
      end

      def min_tvd(bounds)
        bounds.sum do |bound|
          if bound.target > bound.ceiling
            bound.target - bound.ceiling
          elsif bound.target < bound.floor
            bound.floor - bound.target
          else
            0.0
          end
        end / 2.0
      end
    end
  end
end
