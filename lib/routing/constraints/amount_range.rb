# frozen_string_literal: true

module Routing
  module Constraints
    # Сумма заявки должна попадать в диапазон чека провайдера.
    class AmountRange < Base
      def check(context)
        amount = context.operation.amount
        min = context.provider.limit_amount_min
        max = context.provider.limit_amount_max

        if min && amount < min
          return violation("amount_below_minimum", "#{amount} < limit_amount_min #{min}")
        end

        if max && amount > max
          return violation("amount_exceeds_limit", "#{amount} > limit_amount_max #{max}")
        end

        nil
      end
    end
  end
end
