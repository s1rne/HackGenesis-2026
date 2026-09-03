# frozen_string_literal: true

module Routing
  module Constraints
    # Валюта заявки должна поддерживаться провайдером.
    # Если список валют не задан — ограничение неприменимо.
    class Currency < Base
      def check(context)
        return skip if context.provider.currencies.empty?
        return nil if context.provider.accepts_currency?(context.operation.currency)

        violation("currency_not_supported",
                  "#{context.operation.currency} не входит в #{context.provider.currencies.join(', ')}")
      end
    end
  end
end
