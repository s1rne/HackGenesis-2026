# frozen_string_literal: true

require_relative "test_helper"

# Деньги: целые копейки против Float.
#
# Смысл этих проверок не академический. Сравнение «оборот + сумма > дневного
# лимита» стоит в жёстком ограничении, и если оно соврёт на границе, провайдер
# будет исключён из пула без причины — а объяснить это в отчёте будет нечем.
class MoneyTest < Minitest::Test
  Money = Routing::Money

  def test_addition_of_kopecks_does_not_lose_precision
    sum = 3.times.reduce(Money.zero) { |acc, _| acc + 10_000.10 }

    assert_equal 3_000_030, sum.minor
    assert_equal 30_000.30, sum.to_major
    # Тот же счёт на Float даёт 30000.300000000003 и ломает сравнение с лимитом.
    float_sum = 3.times.reduce(0.0) { |acc, _| acc + 10_000.10 }
    assert_operator float_sum, :>, 30_000.30
  end

  def test_turnover_plus_amount_at_the_limit_boundary_does_not_exceed_it
    turnover = Money.from_major(1000.08)
    amount = Money.from_major(2000.16)
    limit = Money.from_major(3000.24)

    projected = turnover + amount

    assert_equal limit, projected
    refute_operator projected, :>, limit, "заявка ровно на границе лимита не должна его превышать"
    # Контрольный выстрел: на Float то же сравнение возвращает true.
    assert_operator(1000.08 + 2000.16, :>, 3000.24)
  end

  def test_ten_additions_of_ten_kopecks_give_exactly_one_rouble
    sum = 10.times.reduce(Money.zero) { |acc, _| acc + 0.1 }

    assert_equal 100, sum.minor
    assert_equal 1, sum.to_major
    assert_operator 10.times.reduce(0.0) { |acc, _| acc + 0.1 }, :<, 1.0
  end

  def test_from_major_accepts_integers_floats_and_money
    assert_equal 150_000_00, Money.from_major(150_000).minor
    assert_equal 1_050, Money.from_major(10.5).minor
    assert_equal 1_050, Money.from_major(Money.from_major(10.5)).minor
    assert_equal 0, Money.from_major(nil).minor
  end

  def test_from_major_parses_human_written_amounts
    assert_equal 100_050, Money.from_major("1 000,50").minor
    assert_equal 100_050, Money.from_major("1_000.50").minor
    assert_equal 4_800_000, Money.from_major("48000").minor
  end

  def test_from_major_rejects_values_that_are_not_amounts
    error = assert_raises(Routing::DataError) { Money.from_major("две тысячи") }
    assert_match(/не похоже на сумму/, error.message)
    assert_raises(Routing::DataError) { Money.from_major(:nope) }
  end

  def test_comparison_and_arithmetic
    assert_operator Money.from_major(100), :>, Money.from_major(99.99)
    assert_equal Money.from_major(1), Money.from_major(0.5) + Money.from_major(0.5)
    assert_equal Money.from_major(0.5), Money.from_major(1) - Money.from_major(0.5)
    assert_predicate Money.from_major(-1), :negative?
    assert_predicate Money.zero, :zero?
  end

  def test_ratio_of_is_safe_on_zero_denominator
    assert_in_delta 0.25, Money.from_major(250).ratio_of(Money.from_major(1000))
    assert_in_delta 0.0, Money.from_major(250).ratio_of(Money.zero)
  end

  def test_serialization_keeps_input_units
    assert_equal 150_000, Money.from_major(150_000).as_json
    assert_equal 1000.5, Money.from_major("1 000,50").as_json
    assert_equal "1000.50", Money.from_major(1000.5).to_s
    assert_equal "150000", Money.from_major(150_000).to_s
  end

  def test_money_is_frozen_and_hashable
    value = Money.from_major(10)

    assert_predicate value, :frozen?
    assert_equal({ Money.from_major(10) => :ok }[value], :ok)
  end
end
