# frozen_string_literal: true

module Routing
  module Strategies
    # Стратегия 2: распределение по доле от объёма в рублях.
    #
    # Считается тем же дефицитом, что и доля по количеству, но в деньгах —
    # и это принципиально другая цель. Десять заявок по 1 000 ₽ и одна на
    # 100 000 ₽ дают одинаковый вклад в count-долю и стократно разный
    # в volume-долю; из-за этого две цели регулярно указывают на разных
    # провайдеров, что и разрешается механизмом согласования в Scorer.
    class VolumeShare < Base
      def raw_score(context)
        target = context.fleet.volume_target(context.provider.id, among: context.pool)
        return nil if target.zero?

        total = context.fleet.total_selected_amount.to_major.to_f + context.operation.amount.to_major.to_f
        return nil if total <= 0

        expected = target * total
        (expected - context.state.selected_amount.to_major.to_f) / total
      end

      def explain(context)
        target = context.fleet.volume_target(context.provider.id, among: context.pool)
        actual = context.fleet.actual_volume_share(context.provider.id)
        return "целевая доля по объёму не задана" if target.zero?

        "доля по объёму #{pct(actual)}% при цели #{pct(target)}% " \
          "(#{context.state.selected_amount} из #{context.fleet.total_selected_amount})"
      end
    end
  end
end
