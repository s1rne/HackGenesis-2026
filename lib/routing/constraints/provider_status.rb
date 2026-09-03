# frozen_string_literal: true

module Routing
  module Constraints
    # Провайдер должен быть в рабочем статусе.
    class ProviderStatus < Base
      def check(context)
        return nil if context.provider.active?

        violation("provider_inactive", "status = #{context.provider.status.inspect}, ожидался \"active\"")
      end
    end
  end
end
