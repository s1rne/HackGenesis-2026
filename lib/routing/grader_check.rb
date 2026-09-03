# frozen_string_literal: true

module Routing
  # Проверка нашей выгрузки моделью проверяющего.
  #
  # Это намеренное повторение логики `scripts/validate_10.rb` внутри проекта,
  # и повторение здесь — не дублирование, а страховка. Причина конкретная:
  # проверяющий считает допустимость провайдера по СНИМКУ состояния, один раз,
  # а роутер — по накопленному состоянию, которое меняется от заявки к заявке.
  # Пока очередь короткая, эти две картины совпадают. На длинной очереди
  # дневные лимиты и счётчики расходятся, и появляются заявки, где мы считаем
  # провайдера недоступным, а проверяющий — доступным.
  #
  # Такое расхождение не видно ни в одной проверке структуры: файл валиден,
  # все поля на месте, все заявки покрыты. Видно его только если посчитать
  # по чужой модели — что здесь и делается.
  #
  # Отдельно проверяются «детерминированные» заявки: те, где по снимку допустим
  # ровно один внешний провайдер. Организаторы сверяют такие случаи с эталоном
  # поимённо, и разойтись на них — самая дорогая из возможных ошибок.
  module GraderCheck
    SELF_PROVIDER = "spacepayments"

    Result = Struct.new(:total, :deterministic, :not_allowed, :deterministic_missed, keyword_init: true) do
      def clean? = not_allowed.empty? && deterministic_missed.empty?
    end

    module_function

    def run(operations:, decisions:, providers:)
      chosen = decisions.to_h { |decision| [decision.operation.id, decision.selected_provider] }
      not_allowed = []
      missed = []
      deterministic = 0

      operations.each do |operation|
        allowed = eligible(operation, providers)
        pick = chosen[operation.id]
        not_allowed << [operation.id, pick, allowed] unless allowed.include?(pick)

        external = allowed - [SELF_PROVIDER]
        next unless external.size == 1

        deterministic += 1
        missed << [operation.id, pick, external.first] unless pick == external.first
      end

      Result.new(total: operations.size, deterministic: deterministic,
                 not_allowed: not_allowed, deterministic_missed: missed)
    end

    # Допустимость по снимку — ровно те условия и в том же порядке, что
    # в скрипте организаторов. Правила состояния (интенсивность) он не
    # проверяет вовсе, и мы здесь тоже не проверяем: задача этой функции —
    # повторить чужую логику, а не улучшить её.
    def eligible(operation, providers)
      amount = operation.amount.to_major.to_f
      bank = operation.bank

      providers.filter_map do |provider|
        next unless provider["status"] == "active"
        next if provider["traffic_percentage"].to_f.zero? && provider["payment_system"] != SELF_PROVIDER
        next if provider["limit_amount_min"] && amount < provider["limit_amount_min"]
        next if provider["limit_amount_max"] && amount > provider["limit_amount_max"]
        next if provider["daily_amount_limit"] &&
                (provider["daily_approved_amount"].to_f + amount) > provider["daily_amount_limit"]
        next if provider["in_progress_count_limit"] &&
                (provider["in_progress_count"].to_i + 1) > provider["in_progress_count_limit"]
        next if provider["in_progress_amount_limit"] &&
                (provider["in_progress_amount"].to_f + amount) > provider["in_progress_amount_limit"]
        next if provider["available_requisites"].to_i.zero?
        next if provider["provider_margin_pct"].to_f > provider["merchant_margin_pct"].to_f &&
                !provider["allow_negative_agreement"]
        next unless bank_allowed?(provider, bank)

        provider["payment_system"]
      end
    end

    def bank_allowed?(provider, bank)
      banks = provider["banks"] || []
      return true if banks.empty?

      provider["exclude_banks"] ? !banks.include?(bank) : banks.include?(bank)
    end

    # Пары «пройдено, что проверяли» — в том же виде, что остальные проверки сдачи.
    def checks(operations:, decisions:, providers_path:)
      payload = Delivery.read_json(providers_path)
      providers = payload.is_a?(Hash) ? payload["providers"] : payload
      return [[false, "не удалось прочитать #{providers_path} для сверки с моделью проверяющего"]] unless providers.is_a?(Array)

      result = run(operations: operations, decisions: decisions, providers: providers)
      [
        [result.not_allowed.empty?,
         "выбранный провайдер допустим по модели проверяющего" +
         (result.not_allowed.empty? ? "" : ": #{describe(result.not_allowed.first(3))}")],
        [result.deterministic_missed.empty?,
         "совпали на #{result.deterministic} заявках, где допустим ровно один провайдер" +
         (result.deterministic_missed.empty? ? "" : ": #{describe(result.deterministic_missed.first(3))}")]
      ]
    end

    def describe(rows)
      rows.map { |id, pick, expected| "#{id} — выбран #{pick || 'никто'}, ожидался #{Array(expected).join('/')}" }
          .join("; ")
    end
  end
end
