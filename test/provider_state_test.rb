# frozen_string_literal: true

require_relative "test_helper"

# Обновление состояния провайдера после каждой заявки.
#
# Жизненный цикл попытки: reserve -> settle_approved | settle_failed.
# Главное здесь — откат: если провайдер отказал, за ним не должно остаться
# ни занятого слота, ни занятого реквизита. Иначе каскад начинает врать,
# а дневная загрузка в отчёте расходится с реальностью.
class ProviderStateTest < Minitest::Test
  PROVIDER = {
    "payment_system" => "acme",
    "status" => "active",
    "traffic_percentage" => 100,
    "daily_amount_limit" => 1_000_000,
    "daily_approved_amount" => 200_000,
    "in_progress_count_limit" => 10,
    "in_progress_count" => 4,
    "in_progress_amount_limit" => 1_000_000,
    "in_progress_amount" => 100_000,
    "available_requisites" => 12,
    "requests_per_minute_limit" => 7
  }.freeze

  def setup
    @provider = build_provider(PROVIDER)
    @state = Routing::ProviderState.new(@provider)
    @operation = build_operation(id: "op_state", amount: 50_000)
  end

  def snapshot
    {
      daily: @state.daily_amount.minor,
      in_progress_count: @state.in_progress_count,
      in_progress_amount: @state.in_progress_amount.minor,
      requisites: @state.available_requisites
    }
  end

  def test_initial_state_comes_from_provider_data
    assert_equal 200_000, @state.daily_amount.to_major
    assert_equal 4, @state.in_progress_count
    assert_equal 100_000, @state.in_progress_amount.to_major
    assert_equal 12, @state.available_requisites
  end

  # --- резерв ---------------------------------------------------------------

  def test_reserve_takes_a_slot_and_a_requisite
    @state.reserve(@operation, at: 1000.0)

    assert_equal 5, @state.in_progress_count, "заявка заняла слот одновременных заявок"
    assert_equal 150_000, @state.in_progress_amount.to_major, "сумма заявки встала в работу"
    assert_equal 11, @state.available_requisites, "заявка заняла реквизит"
    assert_equal 200_000, @state.daily_amount.to_major, "оборот дня резерв не трогает"
    assert_equal 1, @state.attempt_count
  end

  def test_reserve_registers_the_request_for_the_rate_limit
    @state.reserve(@operation, at: 1000.0)

    assert_equal 1, @state.requests_in_window(1000.0, 60.0)
    assert_equal 0, @state.requests_in_window(2000.0, 60.0), "окно скользящее"
  end

  def test_double_reserve_of_the_same_operation_is_a_rule_error
    @state.reserve(@operation, at: 1000.0)
    error = assert_raises(Routing::RuleError) { @state.reserve(@operation, at: 1001.0) }

    assert_equal "provider_state", error.rule
    assert_match(/op_state/, error.message)
  end

  # --- одобрение ------------------------------------------------------------

  def test_approval_moves_the_amount_into_daily_turnover_and_frees_the_slot
    before = snapshot
    @state.reserve(@operation, at: 1000.0)
    @state.settle_approved(@operation)

    assert_equal 250_000, @state.daily_amount.to_major, "сумма перешла в дневной оборот"
    assert_equal before[:in_progress_count], @state.in_progress_count, "слот освобождён"
    assert_equal before[:in_progress_amount], @state.in_progress_amount.minor, "сумма ушла из in-progress"
    assert_equal before[:requisites], @state.available_requisites, "реквизит возвращён"
    assert_equal 1, @state.approved_count
    assert_equal 50_000, @state.approved_amount.to_major
  end

  def test_approval_moves_daily_utilization
    @state.reserve(@operation, at: 1000.0)
    @state.settle_approved(@operation)

    assert_in_delta 0.25, @state.daily_utilization, 1e-9
    assert_equal 750_000, @state.headroom_amount.to_major
  end

  # --- отказ ----------------------------------------------------------------

  def test_decline_returns_everything_back_to_the_initial_values
    before = snapshot
    @state.reserve(@operation, at: 1000.0)
    @state.settle_failed(@operation, :rejected)

    assert_equal before[:in_progress_count], @state.in_progress_count,
                 "после отказа in_progress_count обязан вернуться к исходному"
    assert_equal before[:in_progress_amount], @state.in_progress_amount.minor
    assert_equal before[:requisites], @state.available_requisites,
                 "после отказа available_requisites обязан вернуться к исходному"
    assert_equal before[:daily], @state.daily_amount.minor,
                 "отказ не должен попадать в дневной оборот"
    assert_equal 1, @state.declined_count
    assert_equal 0, @state.approved_count
  end

  def test_timeout_is_counted_separately_from_a_decline
    @state.reserve(@operation, at: 1000.0)
    @state.settle_failed(@operation, :expired)

    assert_equal 1, @state.expired_count
    assert_equal 0, @state.declined_count
    assert_equal 200_000, @state.daily_amount.to_major
  end

  def test_a_long_chain_of_declines_leaves_no_leaked_limits
    before = snapshot
    20.times do |i|
      operation = build_operation(id: "op_#{i}", amount: 10_000 + i)
      @state.reserve(operation, at: 1000.0 + i)
      @state.settle_failed(operation, i.even? ? :rejected : :expired)
    end

    assert_equal before, snapshot, "двадцать отказов не должны сдвинуть ни одного счётчика"
    assert_equal 20, @state.attempt_count
  end

  def test_mixed_run_updates_turnover_only_by_approved_amounts
    3.times do |i|
      operation = build_operation(id: "ok_#{i}", amount: 10_000)
      @state.reserve(operation, at: 1000.0 + i)
      @state.settle_approved(operation)
    end
    2.times do |i|
      operation = build_operation(id: "fail_#{i}", amount: 100_000)
      @state.reserve(operation, at: 1100.0 + i)
      @state.settle_failed(operation, :rejected)
    end

    assert_equal 230_000, @state.daily_amount.to_major
    assert_equal 4, @state.in_progress_count
    assert_equal 12, @state.available_requisites
    assert_in_delta 0.6, @state.observed_conversion, 1e-9
  end

  # --- доля трафика ---------------------------------------------------------

  def test_selection_is_recorded_separately_from_attempts
    @state.reserve(@operation, at: 1000.0)
    @state.settle_approved(@operation)

    assert_equal 0, @state.selected_count, "попытка сама по себе долей трафика не становится"

    @state.record_selection(@operation)

    assert_equal 1, @state.selected_count
    assert_equal 50_000, @state.selected_amount.to_major
  end

  # --- загрузка -------------------------------------------------------------

  def test_load_factor_is_the_worst_measure_across_limits
    @state.reserve(@operation, at: 1000.0)

    measures = {
      daily: @state.daily_utilization,
      count: @state.in_progress_count_utilization,
      amount: @state.in_progress_amount_utilization,
      requisites: @state.requisite_utilization
    }

    assert_in_delta measures.values.max, @state.load_factor(Float::INFINITY), 1e-9,
                    "узкое место определяет самый нагруженный лимит, а не среднее"
  end

  def test_load_factor_includes_intensity_when_time_is_known
    7.times { |i| @state.record_request(1000.0 + i) }

    assert_in_delta 1.0, @state.rate_utilization(1006.0), 1e-9
    assert_in_delta 1.0, @state.load_factor(1006.0), 1e-9
    assert_operator @state.load_factor(Float::INFINITY), :<, 1.0,
                    "без времени интенсивность не учитывается"
  end

  def test_utilizations_are_zero_when_limits_are_absent
    state = Routing::ProviderState.new(build_provider({ "payment_system" => "open", "status" => "active",
                                                        "traffic_percentage" => 100 }))

    assert_in_delta 0.0, state.daily_utilization
    assert_in_delta 0.0, state.in_progress_count_utilization
    assert_in_delta 0.0, state.in_progress_amount_utilization
    assert_in_delta 0.0, state.requisite_utilization
    assert_nil state.headroom_amount
    assert_nil state.turnover_min_gap
  end

  def test_turnover_min_gap_shrinks_as_the_day_goes_on
    state = Routing::ProviderState.new(build_provider(PROVIDER.merge("daily_turnover_min" => 500_000)))

    assert_equal 300_000, state.turnover_min_gap.to_major

    operation = build_operation(id: "big", amount: 400_000)
    state.reserve(operation, at: 1000.0)
    state.settle_approved(operation)

    assert_predicate state.turnover_min_gap, :zero?, "перевыполненное обязательство даёт нулевой недобор, а не отрицательный"
  end

  def test_snapshot_reports_the_numbers_the_report_relies_on
    @state.reserve(@operation, at: 1000.0)
    @state.settle_approved(@operation)
    @state.record_selection(@operation)
    row = @state.to_h(1000.0)

    assert_equal "acme", row[:provider]
    assert_equal 250_000, row[:daily_amount]
    assert_equal 1_000_000, row[:daily_limit]
    assert_in_delta 25.0, row[:daily_utilization_pct]
    assert_equal 1, row[:selected_count]
    assert_equal 1, row[:approved]
  end
end
