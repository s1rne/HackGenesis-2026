# frozen_string_literal: true

module Routing
  module Constraints
    # Верхнее финансовое обязательство «не более X ₽/сутки».
    # Отдельное правило от дневного лимита: лимит — техническая ёмкость гейта,
    # обязательство — условие соглашения, и нарушаются они по разным причинам.
    class DailyTurnoverMax < Base
      def self.stateful? = true

      def check(context)
        cap = context.provider.daily_turnover_max
        return skip if cap.nil?

        projected = context.state.daily_amount + context.operation.amount
        return nil if projected <= cap

        violation("daily_turnover_max_exceeded",
                  "#{projected} > daily_turnover_max #{cap}")
      end
    end
  end
end
