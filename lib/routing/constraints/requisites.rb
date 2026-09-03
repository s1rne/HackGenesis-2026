# frozen_string_literal: true

module Routing
  module Constraints
    # Должен остаться хотя бы один свободный реквизит (терминал).
    class Requisites < Base
      def check(context)
        available = context.state.available_requisites
        return skip if available.nil?
        return nil if available.positive?

        violation("no_available_requisites", "available_requisites = #{available}")
      end
    end
  end
end
