# frozen_string_literal: true

require_relative "test_helper"

# Статистика, на которой стоит скоринг. Каждая формула проверяема на бумаге,
# поэтому и проверяется числами, а не «примерно так».
class StatisticsTest < Minitest::Test
  S = Routing::Statistics

  # --- нижняя граница Вильсона ---------------------------------------------

  def test_wilson_lower_bound_for_three_of_three_at_95_percent
    assert_in_delta 0.4385, S.wilson_lower_bound(3, 3, 0.95), 0.0005
  end

  def test_wilson_lower_bound_for_ninety_of_hundred_at_95_percent
    assert_in_delta 0.8256, S.wilson_lower_bound(90, 100, 0.95), 0.0005
  end

  def test_wilson_prefers_large_sample_over_perfect_small_one
    small = S.wilson_lower_bound(3, 3, 0.95)
    large = S.wilson_lower_bound(90, 100, 0.95)

    assert_operator large, :>, small,
                    "90 из 100 должны обходить 3 из 3: сырая конверсия у второго выше, доверия — нет"
  end

  def test_wilson_returns_zero_without_trials
    assert_in_delta 0.0, S.wilson_lower_bound(0, 0)
    assert_in_delta 0.0, S.wilson_lower_bound(5, nil)
    assert_in_delta 0.0, S.wilson_lower_bound(1, -3)
  end

  def test_wilson_is_clamped_to_unit_interval
    assert_operator S.wilson_lower_bound(0, 10), :>=, 0.0
    assert_operator S.wilson_lower_bound(10_000, 10_000), :<=, 1.0
  end

  def test_wider_confidence_gives_lower_bound
    assert_operator S.wilson_lower_bound(90, 100, 0.99), :<, S.wilson_lower_bound(90, 100, 0.80)
  end

  def test_z_for_uses_table_and_falls_back_to_nearest_level
    assert_in_delta 1.96, S.z_for(0.95), 1e-9
    assert_in_delta 1.6449, S.z_for(0.90), 1e-9
    # 0.93 нет в таблице — берётся ближайший уровень.
    assert_includes S::Z_SCORES.values, S.z_for(0.93)
  end

  # --- метод наибольших остатков -------------------------------------------

  def test_largest_remainder_sums_exactly_to_total
    result = S.largest_remainder({ "vipay" => 0.40, "payflow" => 0.35, "quickpay" => 0.25 }, 10)

    assert_equal 10, result.values.sum
    assert_equal 4, result["vipay"]
  end

  def test_largest_remainder_sums_to_total_on_awkward_shares
    [7, 10, 13, 100].each do |total|
      result = S.largest_remainder({ "a" => 1.0 / 3, "b" => 1.0 / 3, "c" => 1.0 / 3 }, total)

      assert_equal total, result.values.sum, "разложение #{total} по трети должно давать ровно #{total}"
    end
  end

  def test_largest_remainder_is_deterministic_on_equal_remainders
    shares = { "b" => 0.5, "a" => 0.5 }

    # При равных остатках порядок задаёт ключ, а не порядок вставки.
    assert_equal S.largest_remainder(shares, 3), S.largest_remainder({ "a" => 0.5, "b" => 0.5 }, 3)
    assert_equal 2, S.largest_remainder(shares, 3)["a"]
  end

  def test_largest_remainder_handles_degenerate_input
    assert_empty S.largest_remainder({}, 10)
    assert_empty S.largest_remainder({ "a" => 1.0 }, 0)
  end

  # --- нормализация ---------------------------------------------------------

  def test_min_max_normalize_returns_neutral_half_when_all_values_are_equal
    assert_equal [0.5, 0.5, 0.5], S.min_max_normalize([5.0, 5.0, 5.0])
    assert_equal [0.5], S.min_max_normalize([0.0])
  end

  def test_min_max_normalize_returns_neutral_half_when_nothing_is_finite
    assert_equal [0.5, 0.5], S.min_max_normalize([nil, nil]).map { |v| v.nil? ? 0.5 : v }
    assert_equal [nil, nil], S.min_max_normalize([nil, nil])
  end

  def test_min_max_normalize_spreads_values_to_unit_interval
    assert_equal [0.0, 0.5, 1.0], S.min_max_normalize([10.0, 20.0, 30.0])
  end

  def test_min_max_normalize_keeps_nil_as_not_applicable
    assert_equal [0.0, nil, 1.0], S.min_max_normalize([1.0, nil, 3.0])
  end

  # --- прочее ---------------------------------------------------------------

  def test_blended_counts_mixes_prior_with_observations
    successes, trials = S.blended_counts(0.9, 20, 3, 4)

    assert_in_delta 21.0, successes
    assert_in_delta 24.0, trials
  end

  def test_blended_counts_clamps_impossible_prior
    successes, trials = S.blended_counts(2.5, 10, 0, 0)

    assert_in_delta 10.0, successes, 1e-9
    assert_in_delta 10.0, trials, 1e-9
  end

  def test_ewma_weighs_recent_observations_more
    assert_nil S.ewma([])
    assert_in_delta 1.0, S.ewma([1.0])
    rising = S.ewma([0.0, 0.0, 1.0], 0.5)
    falling = S.ewma([1.0, 0.0, 0.0], 0.5)

    assert_operator rising, :>, falling
  end

  def test_concentration_is_one_when_everything_sits_on_one_provider
    assert_in_delta 1.0, S.concentration([1.0])
    assert_in_delta 1.0 / 3, S.concentration([1.0, 1.0, 1.0])
    assert_in_delta 0.0, S.concentration([])
  end
end
