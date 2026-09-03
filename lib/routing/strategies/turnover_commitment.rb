# frozen_string_literal: true

module Routing
  module Strategies
    # Стратегия 7: финансовые обязательства по обороту.
    #
    # Гейт нередко выдан на условии «не менее X ₽ в сутки». Невыполнение —
    # это не просто перекос распределения, а нарушение договорённости с
    # партнёром, поэтому цель по умолчанию стоит в старшем эшелоне скоринга
    # и способна перебить и долю трафика, и конверсию.
    #
    # Срочность растёт нелинейно: пока недобор мал, цель почти не вмешивается,
    # но чем ближе конец суток при незакрытом обязательстве, тем сильнее
    # провайдер тянет заявки на себя.
    class TurnoverCommitment < Base
      def raw_score(context)
        target = context.provider.daily_turnover_min
        return nil if target.nil? || target.zero?

        gap = context.state.turnover_min_gap
        return 0.0 if gap.nil? || gap.zero?

        (gap.ratio_of(target)**exponent).clamp(0.0, 1.0)
      end

      def explain(context)
        target = context.provider.daily_turnover_min
        return "обязательство по минимальному обороту не задано" if target.nil? || target.zero?

        gap = context.state.turnover_min_gap
        return "минимальный оборот #{target} уже выполнен (#{context.state.daily_amount})" if gap.nil? || gap.zero?

        "не добрано #{gap} до обязательства #{target} " \
          "(#{pct(1 - gap.ratio_of(target))}% выполнено)"
      end

      private

      def exponent = setting("urgency_exponent", 0.5).to_f
    end
  end
end
