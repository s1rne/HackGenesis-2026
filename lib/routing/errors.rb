# frozen_string_literal: true

module Routing
  # Базовая ошибка домена. Всё, что мы бросаем осознанно, наследуется от неё,
  # поэтому CLI может отличить понятную ошибку конфигурации от настоящего бага.
  class Error < StandardError; end

  # Входные данные не удалось прочитать или они не похожи ни на один известный формат.
  class DataError < Error
    attr_reader :source

    def initialize(message, source: nil)
      @source = source
      super(source ? "#{source}: #{message}" : message)
    end
  end

  # Конфигурация ссылается на неизвестное правило, стратегию или параметр.
  class ConfigError < Error; end

  # Ошибка внутри правила маршрутизации: правило не смогло вынести решение.
  class RuleError < Error
    attr_reader :rule

    def initialize(message, rule: nil)
      @rule = rule
      super(rule ? "правило #{rule}: #{message}" : message)
    end
  end
end
