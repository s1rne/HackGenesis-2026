# frozen_string_literal: true

module Routing
  module Ingest
    # Копилка замечаний к входным данным.
    #
    # Мы принципиально не падаем на первом кривом поле: реальный файл провайдеров
    # почти всегда чем-то отличается от документации. Вместо исключения мы берём
    # разумное значение по умолчанию, записываем замечание и показываем весь
    # список в отчёте — так видно, на каких допущениях построен результат.
    class Issues
      Issue = Struct.new(:severity, :source, :field, :message, keyword_init: true) do
        def to_h = { severity: severity, source: source, field: field, message: message }
        def to_s = "[#{severity}] #{source}#{field ? " .#{field}" : ""}: #{message}"
      end

      SEVERITIES = %i[info warning error].freeze

      def initialize = @items = []

      def add(severity, source, message, field: nil)
        raise ArgumentError, "неизвестная важность #{severity}" unless SEVERITIES.include?(severity)

        @items << Issue.new(severity: severity, source: source, field: field, message: message)
        self
      end

      def info(source, message, field: nil) = add(:info, source, message, field: field)
      def warning(source, message, field: nil) = add(:warning, source, message, field: field)
      def error(source, message, field: nil) = add(:error, source, message, field: field)

      def to_a = @items.dup
      def empty? = @items.empty?
      def any_errors? = @items.any? { |i| i.severity == :error }
      def count_by_severity = @items.group_by(&:severity).transform_values(&:size)
      def as_json = @items.map(&:to_h)
      def each(&block) = @items.each(&block)
      include Enumerable
    end
  end
end
