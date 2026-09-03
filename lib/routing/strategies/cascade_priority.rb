# frozen_string_literal: true

module Routing
  module Strategies
    # Стратегия 3: очередь в каскаде по полю priority.
    #
    # Меньшее число — выше место в очереди. Провайдер без приоритета уходит
    # в конец, но не исключается: отсутствие настройки не должно быть приговором.
    class CascadePriority < Base
      UNRANKED = 10_000

      def raw_score(context)
        priority = context.provider.priority
        -(priority || setting("default_priority", UNRANKED)).to_f
      end

      def explain(context)
        priority = context.provider.priority
        return "приоритет в каскаде не задан, поставлен в конец очереди" if priority.nil?

        "приоритет в каскаде #{priority}"
      end
    end
  end
end
