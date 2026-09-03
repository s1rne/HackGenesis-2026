# frozen_string_literal: true

module Routing
  # Каталог причин решений.
  #
  # Код причины — машинный ключ, по которому агрегируется отчёт (skip_reasons),
  # текст — человеческая формулировка для чтения глазами. Оба живут в одном
  # месте, поэтому в выгрузке не может появиться причина, которую невозможно
  # объяснить словами, а в отчёте — причина без агрегата.
  module Reasons
    CATALOG = {
      # --- отсев жёсткими ограничениями ---
      "provider_inactive" => { category: :hard, text: "провайдер не в статусе active" },
      "zero_traffic_share" => { category: :hard, text: "провайдеру не выделена доля трафика" },
      "currency_not_supported" => { category: :hard, text: "провайдер не работает с валютой заявки" },
      "amount_below_minimum" => { category: :hard, text: "сумма меньше минимального чека провайдера" },
      "amount_exceeds_limit" => { category: :hard, text: "сумма больше максимального чека провайдера" },
      "daily_limit_exceeded" => { category: :hard, text: "заявка не помещается в дневной лимит по обороту" },
      "daily_turnover_max_exceeded" => { category: :hard, text: "заявка нарушает верхнее обязательство по обороту" },
      "in_progress_count_limit" => { category: :hard, text: "исчерпан лимит одновременных заявок" },
      "in_progress_amount_limit" => { category: :hard, text: "исчерпан лимит суммы заявок в работе" },
      "bank_not_in_list" => { category: :hard, text: "банк заявки не входит в список поддерживаемых" },
      "bank_excluded" => { category: :hard, text: "банк заявки в списке исключений провайдера" },
      "bank_unknown" => { category: :hard, text: "банк заявки не определён, а провайдер работает по белому списку" },
      "negative_margin" => { category: :hard, text: "маржа провайдера выше маржи мерчанта" },
      "no_available_requisites" => { category: :hard, text: "нет свободных реквизитов" },
      "rate_limit_exceeded" => { category: :hard, text: "превышен лимит заявок в минуту" },

      # --- отсев на этапе выбора ---
      "lower_score" => { category: :soft, text: "прошёл ограничения, но уступил по итоговому скорингу" },
      "not_reached_in_cascade" => { category: :soft, text: "не понадобился: заявку принял провайдер выше по каскаду" },
      "provider_declined" => { category: :attempt, text: "провайдер отказал в обработке" },
      "provider_timeout" => { category: :attempt, text: "провайдер не ответил вовремя" },

      # --- причины выбора ---
      "only_eligible_provider" => { category: :selection, text: "единственный провайдер, прошедший ограничения" },
      "traffic_share_deficit" => { category: :selection, text: "отстаёт от целевой доли по количеству заявок" },
      "volume_share_deficit" => { category: :selection, text: "отстаёт от целевой доли по объёму" },
      "highest_conversion" => { category: :selection, text: "лучшая оценка конверсии среди допустимых" },
      "amount_band_match" => { category: :selection, text: "сумма заявки попадает в его целевой диапазон" },
      "highest_cascade_priority" => { category: :selection, text: "первый по приоритету в каскаде" },
      "lowest_load" => { category: :selection, text: "наименее загружен по лимитам" },
      "turnover_commitment" => { category: :selection, text: "не добран минимальный дневной оборот по обязательству" },
      "best_margin" => { category: :selection, text: "лучшая маржинальность для мерчанта" },
      "best_combined_score" => { category: :selection, text: "лучший суммарный скоринг по активным целям" },
      "cascade_retry" => { category: :selection, text: "следующий в каскаде после отказа предыдущего" },
      "fallback_self_provider" => { category: :selection, text: "внешний пул пуст, ушли на собственного провайдера" },
      "no_provider_available" => { category: :selection, text: "не нашлось ни одного провайдера, включая fallback" }
    }.freeze

    # Какая цель какой причиной выбора представляется в объяснении.
    STRATEGY_REASON = {
      "count_share" => "traffic_share_deficit",
      "volume_share" => "volume_share_deficit",
      "conversion" => "highest_conversion",
      "amount_band" => "amount_band_match",
      "cascade_priority" => "highest_cascade_priority",
      "load_balance" => "lowest_load",
      "turnover_commitment" => "turnover_commitment",
      "margin" => "best_margin"
    }.freeze

    module_function

    def known?(code) = CATALOG.key?(code.to_s)

    def text(code)
      entry = CATALOG[code.to_s]
      entry ? entry[:text] : code.to_s.tr("_", " ")
    end

    def category(code)
      entry = CATALOG[code.to_s]
      entry ? entry[:category] : :other
    end

    def for_strategy(id) = STRATEGY_REASON.fetch(id.to_s, "best_combined_score")

    def hard_codes = CATALOG.select { |_, v| v[:category] == :hard }.keys
  end
end
