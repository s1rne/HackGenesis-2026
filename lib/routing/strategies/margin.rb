# frozen_string_literal: true

module Routing
  module Strategies
    # Дополнительная цель: маржинальность.
    #
    # Жёсткое ограничение отсекает только убыточных провайдеров. Но между двумя
    # прибыльными выбор тоже не безразличен: при прочих равных заявка должна
    # уходить туда, где мерчант зарабатывает больше. Вес по умолчанию небольшой —
    # деньги на одной заявке не должны перевешивать обязательства и доли.
    class Margin < Base
      def raw_score(context)
        provider = context.provider
        gap = provider.margin_gap
        return -provider.provider_margin_pct.to_f if gap.nil?

        gap.to_f
      end

      def explain(context)
        provider = context.provider
        gap = provider.margin_gap
        return "маржа мерчанта не задана, учитываем только комиссию провайдера #{provider.provider_margin_pct}%" if gap.nil?

        "маржа мерчанта #{provider.merchant_margin_pct}% минус комиссия провайдера " \
          "#{provider.provider_margin_pct}% = #{gap.round(2)} п.п."
      end
    end
  end
end
