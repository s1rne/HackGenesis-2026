# frozen_string_literal: true

module Routing
  module Constraints
    # Маржа провайдера не должна превышать маржу мерчанта — иначе выплата
    # уходит в минус. Исключение делается только при явном соглашении
    # `allow_negative_agreement`.
    class Margin < Base
      def check(context)
        provider = context.provider
        return skip unless provider.margin_defined?
        return nil if provider.allow_negative_agreement
        return nil if provider.provider_margin_pct <= provider.merchant_margin_pct

        violation("negative_margin",
                  "provider_margin_pct #{provider.provider_margin_pct} > " \
                  "merchant_margin_pct #{provider.merchant_margin_pct}, allow_negative_agreement не выставлен")
      end
    end
  end
end
