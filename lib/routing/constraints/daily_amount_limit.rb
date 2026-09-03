# frozen_string_literal: true

module Routing
  module Constraints
    # Заявка не должна выводить дневной оборот за верхний лимит.
    # Проверяем «оборот + сумма», а не «оборот», иначе последняя заявка дня
    # спокойно перевалит за лимит.
    class DailyAmountLimit < Base
      def check(context)
        limit = context.provider.daily_amount_limit
        return skip if limit.nil?

        projected = context.state.daily_amount + context.operation.amount
        return nil if projected <= limit

        violation("daily_limit_exceeded",
                  "#{context.state.daily_amount} + #{context.operation.amount} = #{projected} " \
                  "> daily_amount_limit #{limit}")
      end
    end
  end
end
