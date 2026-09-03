# frozen_string_literal: true

module Routing
  # Нормализация названий банков.
  #
  # В списках провайдеров банк может быть записан как "Сбербанк", "sberbank",
  # "SBER" или "ПАО Сбербанк". Сравнивать такие строки как есть — верный способ
  # молча исключить подходящего провайдера, поэтому все имена приводятся к
  # одному виду, а нестандартные написания разруливаются таблицей синонимов
  # из конфигурации (`bank_aliases`).
  module Bank
    LEGAL_FORMS = /\A(пао|оао|ооо|зао|ао|jsc|pjsc|llc|ltd)\s+/i
    NOISE = /\s+(банк|bank)\z/i

    module_function

    def normalize(name, aliases = {})
      return nil if name.nil?

      text = name.to_s.strip.downcase.gsub(/[«»"']/, "").gsub(/\s+/, " ")
      text = text.sub(LEGAL_FORMS, "").sub(NOISE, "").strip
      text = text.gsub(/[^a-zа-яё0-9]+/, "_").gsub(/\A_+|_+\z/, "")
      aliases.fetch(text, text)
    end

    def normalize_all(names, aliases = {})
      Array(names).map { |name| normalize(name, aliases) }.compact.uniq
    end
  end
end
