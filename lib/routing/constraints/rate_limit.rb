# frozen_string_literal: true

module Routing
  module Constraints
    # Ограничение интенсивности: не более N заявок в минуту на провайдера.
    # Окно скользящее и считается по времени заявки, а не по номеру в очереди,
    # поэтому разрежённый поток не упирается в лимит искусственно.
    class RateLimit < Base
      def self.stateful? = true

      def check(context)
        limit = context.provider.requests_per_minute_limit
        return skip if limit.nil?

        window = setting("window_sec", 60).to_f
        used = context.state.requests_in_window(context.at, window)
        return nil if used + 1 <= limit

        violation("rate_limit_exceeded",
                  "за последние #{window.round} с отправлено #{used} заявок при лимите #{limit}/мин")
      end
    end
  end
end
