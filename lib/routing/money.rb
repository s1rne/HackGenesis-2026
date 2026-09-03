# frozen_string_literal: true

module Routing
  # Деньги хранятся в минорных единицах (копейках) целым числом.
  #
  # Причина простая: суммы лимитов и оборотов складываются сотни раз за прогон,
  # и на Float 0.1 + 0.2 != 0.3 — сравнение «оборот + сумма > дневного лимита»
  # начинает врать на границе. Целое число копеек убирает этот класс ошибок
  # полностью, а наружу мы всегда отдаём привычные рубли.
  class Money
    include Comparable

    SUBUNITS = 100

    attr_reader :minor

    def self.from_major(value)
      return value if value.is_a?(Money)
      return zero if value.nil?

      case value
      when Integer then new(value * SUBUNITS)
      when Numeric then new((value * SUBUNITS).round)
      when String then from_major(parse_numeric(value))
      else
        raise DataError, "не похоже на сумму: #{value.inspect}"
      end
    end

    def self.parse_numeric(string)
      cleaned = string.strip.tr(",", ".").gsub(/[\s _]/, "")
      raise DataError, "не похоже на сумму: #{string.inspect}" unless cleaned.match?(/\A-?\d+(\.\d+)?\z/)

      cleaned.include?(".") ? cleaned.to_f : cleaned.to_i
    end

    def self.zero
      @zero ||= new(0)
    end

    def initialize(minor)
      @minor = Integer(minor)
      freeze
    end

    def +(other) = Money.new(minor + Money.from_major(other).minor)
    def -(other) = Money.new(minor - Money.from_major(other).minor)
    def *(factor) = Money.new((minor * factor).round)
    def /(divisor) = divisor.zero? ? Money.zero : Money.new((minor / divisor.to_f).round)

    def <=>(other)
      return nil unless other

      minor <=> Money.from_major(other).minor
    end

    def zero? = minor.zero?
    def positive? = minor.positive?
    def negative? = minor.negative?

    # Доля от другой суммы, 0.0 если знаменатель нулевой.
    def ratio_of(other)
      other = Money.from_major(other)
      return 0.0 if other.zero?

      minor.to_f / other.minor
    end

    # Наружу — в тех же единицах, в которых пришли данные.
    def to_major
      return minor / SUBUNITS if (minor % SUBUNITS).zero?

      (minor.to_f / SUBUNITS).round(2)
    end

    def to_json(*args) = to_major.to_json(*args)
    def as_json = to_major
    def to_s = format("%.2f", minor.to_f / SUBUNITS).sub(/\.00\z/, "")
    def inspect = "#<Money #{self}>"
    def hash = minor.hash
    def eql?(other) = other.is_a?(Money) && other.minor == minor
  end
end
