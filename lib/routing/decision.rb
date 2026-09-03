# frozen_string_literal: true

module Routing
  # Решение по одной заявке — то, что уезжает в routing_decisions.json.
  #
  # Формат обязательных полей задан организаторами и не обсуждается:
  # operation_id, selected_provider, attempts (provider / decision / reason),
  # simulated_result, latency_sec. Всё остальное — дополнительные поля,
  # которые не мешают автопроверке, но позволяют человеку проследить решение
  # до конца: скоринг каждого кандидата, хронология каскада, деградация целей.
  class Decision
    attr_reader :operation, :selected_provider, :attempts, :simulated_result, :latency_sec,
                :selection_reason, :selection_details, :ranking, :events, :cascade_path, :strategy_profile

    def initialize(operation:, selected_provider:, attempts:, simulated_result:, latency_sec:,
                   selection_reason: nil, selection_details: nil, ranking: [], events: [],
                   cascade_path: [], strategy_profile: nil)
      @operation = operation
      @selected_provider = selected_provider
      @attempts = attempts
      @simulated_result = simulated_result
      @latency_sec = latency_sec
      @selection_reason = selection_reason
      @selection_details = selection_details
      @ranking = ranking
      @events = events
      @cascade_path = cascade_path
      @strategy_profile = strategy_profile
    end

    def approved? = simulated_result == "approved"

    # Компактная форма — ровно контракт автопроверки, без единого лишнего поля.
    # Нужна как страховка: если валидатор организаторов окажется строже
    # объявленного, у нас есть файл, к которому не придраться.
    def to_strict_h
      {
        "operation_id" => operation.id,
        "selected_provider" => selected_provider,
        "attempts" => attempts.map { |a| a.slice("provider", "decision", "reason", "details").compact },
        "simulated_result" => simulated_result,
        "latency_sec" => latency_sec
      }
    end

    # Полная форма — то же самое плюс объяснение.
    def to_h
      to_strict_h.merge(
        "attempts" => attempts,
        "amount" => operation.amount.as_json,
        "bank" => operation.bank,
        "selection" => {
          "reason" => selection_reason,
          "details" => selection_details,
          "profile" => strategy_profile,
          "candidates" => ranking
        }.compact,
        "cascade" => {
          "path" => cascade_path,
          "attempts_made" => cascade_path.size
        },
        "events" => events
      ).compact
    end
  end
end
