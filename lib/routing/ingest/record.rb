# frozen_string_literal: true

module Routing
  module Ingest
    # Одна запись входных данных (провайдер или заявка), прочитанная терпимо к формату.
    #
    # Каждый геттер отвечает на вопрос «есть ли такое поле под любым из известных
    # имён и приводится ли оно к нужному типу». Если нет — берётся default,
    # а в Issues попадает замечание с указанием источника и поля.
    class Record
      TRUE_VALUES = %w[true yes y 1 on active enabled да истина].freeze
      FALSE_VALUES = %w[false no n 0 off inactive disabled нет ложь].freeze

      attr_reader :raw, :source

      def initialize(raw, field_map:, issues:, source:)
        @raw = raw.is_a?(Hash) ? raw : {}
        @field_map = field_map
        @issues = issues
        @source = source
        @index = {}
        @raw.each { |k, v| @index[FieldMap.normalize_key(k)] = v }
        @touched = []
      end

      # Сырое значение поля по любому из синонимов; nil, если поля нет.
      def raw_value(canonical)
        @field_map.candidates_for(canonical).each do |key|
          next unless @index.key?(key)

          @touched << key
          value = @index[key]
          return value unless value.nil? || (value.is_a?(String) && value.strip.empty?)
        end
        nil
      end

      def key?(canonical) = !raw_value(canonical).nil?

      # Ключи входной записи, которые не соответствуют ни одному известному полю.
      # Их мы не выбрасываем — они едут дальше в `raw` и попадают в отчёт,
      # чтобы не потерять параметр, о котором мы пока не знаем.
      def unrecognized_keys = @index.keys - @touched

      def string(canonical, default: nil)
        value = raw_value(canonical)
        value.nil? ? default : value.to_s.strip
      end

      def string!(canonical)
        value = string(canonical)
        raise DataError.new("обязательное поле #{canonical} отсутствует", source: source) if value.nil? || value.empty?

        value
      end

      def integer(canonical, default: nil)
        coerce_number(canonical, default) { |number| number.round }
      end

      def float(canonical, default: nil)
        coerce_number(canonical, default, &:to_f)
      end

      def money(canonical, default: nil)
        value = raw_value(canonical)
        return default.nil? ? nil : Money.from_major(default) if value.nil?

        begin
          Money.from_major(value)
        rescue DataError
          note(:warning, canonical, "значение #{value.inspect} не похоже на сумму, взято #{default.inspect}")
          default.nil? ? nil : Money.from_major(default)
        end
      end

      # Доля в диапазоне 0..1. Данные приходят и как 0.87, и как 87 — оба
      # варианта встречаются в реальных выгрузках, поэтому определяем по величине.
      def ratio(canonical, default: nil)
        value = float(canonical)
        return default if value.nil?

        if value > 1.0
          note(:info, canonical, "значение #{value} прочитано как проценты -> #{(value / 100.0).round(4)}") if value > 100.0
          value / 100.0
        elsif value.negative?
          note(:warning, canonical, "отрицательная доля #{value}, взят 0")
          0.0
        else
          value
        end
      end

      # Процент в диапазоне 0..100 — там, где исходная величина по смыслу процент.
      def percent(canonical, default: nil)
        value = float(canonical)
        return default if value.nil?

        value
      end

      def boolean(canonical, default: false)
        value = raw_value(canonical)
        return default if value.nil?
        return value if [true, false].include?(value)
        return !value.zero? if value.is_a?(Numeric)

        normalized = value.to_s.strip.downcase
        return true if TRUE_VALUES.include?(normalized)
        return false if FALSE_VALUES.include?(normalized)

        note(:warning, canonical, "значение #{value.inspect} не похоже на да/нет, взято #{default}")
        default
      end

      # Список строк. Принимает и массив, и строку через запятую/точку с запятой.
      def list(canonical, default: [])
        value = raw_value(canonical)
        return default.dup if value.nil?
        # true/false в поле списка — это флаг режима, а не элемент списка.
        return default.dup if [true, false].include?(value)

        items = value.is_a?(Array) ? value : value.to_s.split(/[,;|]/)
        items.map { |item| item.to_s.strip }.reject(&:empty?)
      end

      def time(canonical, default: nil)
        value = raw_value(canonical)
        return default if value.nil?
        return value if value.is_a?(Time)
        return Time.at(value).utc if value.is_a?(Numeric)

        begin
          Time.parse(value.to_s)
        rescue ArgumentError, TypeError
          note(:warning, canonical, "значение #{value.inspect} не разобралось как время")
          default
        end
      end

      # Записать замечание к этой записи. Публичный метод: модели тоже
      # подставляют значения по умолчанию, и делать это молча нельзя.
      def note(severity, field, message) = @issues.add(severity, source, message, field: field.to_s)

      private

      def coerce_number(canonical, default)
        value = raw_value(canonical)
        return default if value.nil?
        return yield(value) if value.is_a?(Numeric)

        text = value.to_s.strip.tr(",", ".").gsub(/[\s_]/, "")
        unless text.match?(/\A-?\d+(\.\d+)?\z/)
          note(:warning, canonical, "значение #{value.inspect} не число, взято #{default.inspect}")
          return default
        end

        yield(text.include?(".") ? text.to_f : text.to_i)
      end

    end
  end
end
