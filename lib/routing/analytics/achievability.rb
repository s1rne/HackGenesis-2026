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
      Bound = Struct.new(:provider, :target, :floor, :ceiling, :verdict, :blocking_reasons, keyword_init: true)

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

        bounds = @fleet.routable.map do |provider|
          build_bound(provider, forced[provider.id] / total, capacity[provider.id] / total, operations)
        end

        {
          "operations" => operations.size,
          "unroutable" => unroutable,
          "structural_constraints" => @constraints.map(&:id),
          "bounds" => bounds.to_h { |bound| [bound.provider, bound_to_h(bound)] },
          "verdict" => overall_verdict(bounds),
          "min_total_variation_distance" => min_tvd(bounds).round(4)
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

      def build_bound(provider, floor, ceiling, operations)
        target = @fleet.count_target(provider.id)
        verdict = if target > ceiling + 1e-9
                    "недостижима сверху"
                  elsif target < floor - 1e-9
                    "недостижима снизу"
                  else
                    "достижима"
                  end

        Bound.new(provider: provider.id, target: target, floor: floor, ceiling: ceiling,
                  verdict: verdict,
                  blocking_reasons: verdict == "недостижима сверху" ? blocking_reasons(provider, operations) : {})
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
          "verdict" => bound.verdict,
          "blocking_reasons" => bound.blocking_reasons.empty? ? nil : bound.blocking_reasons
        }.compact
      end

      def overall_verdict(bounds)
        broken = bounds.reject { |bound| bound.verdict == "достижима" }
        return "целевое распределение достижимо структурными ограничениями" if broken.empty?

        broken.map do |bound|
          "цель #{(bound.target * 100).round(1)}% на #{bound.provider} #{bound.verdict}: " \
            "коридор #{(bound.floor * 100).round(1)}..#{(bound.ceiling * 100).round(1)}%" \
            "#{bound.blocking_reasons.empty? ? '' : ", причина — #{bound.blocking_reasons.keys.first}"}"
        end.join("; ")
      end

      # Минимально возможное отклонение от целей: каждая цель подтягивается
      # к своему коридору, остаток отклонения уже неустраним.
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
