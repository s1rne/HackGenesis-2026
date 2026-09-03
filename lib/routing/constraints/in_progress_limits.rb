# frozen_string_literal: true

module Routing
  module Constraints
    # Лимиты на одновременно обрабатываемые заявки — по количеству и по сумме.
    class InProgressLimits < Base
      def check(context)
        count_limit = context.provider.in_progress_count_limit
        if count_limit && context.state.in_progress_count + 1 > count_limit
          return violation("in_progress_count_limit",
                           "#{context.state.in_progress_count} + 1 > in_progress_count_limit #{count_limit}")
        end

        amount_limit = context.provider.in_progress_amount_limit
        if amount_limit
          projected = context.state.in_progress_amount + context.operation.amount
          if projected > amount_limit
            return violation("in_progress_amount_limit",
                             "#{projected} > in_progress_amount_limit #{amount_limit}")
          end
        end

        nil
      end
    end
  end
end
