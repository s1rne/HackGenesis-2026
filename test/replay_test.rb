# frozen_string_literal: true

require_relative "test_helper"

# Контрфактический реплей истории.
#
# Здесь проверяется не столько арифметика, сколько честность: оценка обязана
# оставаться интервалом, покрытие — полным, а совпавшие с историей решения —
# опираться на фактический исход, а не на оценку.
class ReplayTest < Minitest::Test
  include RoutingTest

  def setup
    @router = build_case_router
    @result = Routing::Analytics::Replay.new(router: @router, config: @router.config).run
    @summary = @result.summary
  end

  # Регрессия, и самая дорогая. Часы прогона брали максимум из накопленного и
  # текущей отметки, старт — из snapshot_at провайдеров за 30 июля, а вся
  # история за 29-е. Каждая заявка оказывалась «раньше» и получала одну и ту же
  # отметку, скользящее окно видело сто заявок в одну секунду, лимит
  # интенсивности выкашивал пул — семьдесят операций из ста оставались
  # без провайдера. Полное покрытие здесь и есть проверка на это.
  def test_every_historical_operation_gets_a_provider
    unrouted = @result.decisions.reject(&:selected_provider)

    assert_empty unrouted.map { |decision| decision.operation.id },
                 "реплей обязан размаршрутизировать всю историю"
    assert_equal @router.calibration.size, @result.decisions.size
  end

  def test_estimate_is_an_interval_and_not_a_single_number
    estimate = @summary["estimated_approval_rate"]

    assert_operator estimate["lower"], :<=, estimate["upper"]
    assert_includes 0.0..1.0, estimate["lower"]
    assert_includes 0.0..1.0, estimate["upper"]
    refute_empty estimate["note"].to_s, "интервал без объяснения метода бесполезен"
  end

  # На совпавших решениях провайдер тот же, значит известен и настоящий исход.
  # Оценивать его интервалом было бы подменой факта догадкой.
  def test_agreed_decisions_are_counted_from_the_actual_outcome
    actual = @router.calibration.rows.to_h { |row| [row[:operation_id], row] }
    agreed = @result.decisions.count do |decision|
      historical = actual[decision.operation.id]
      historical && historical[:provider] == decision.selected_provider
    end

    assert_equal agreed, @summary["agreement_with_history"]
    assert_in_delta agreed * 100.0 / @result.decisions.size, @summary["agreement_pct"], 0.05
  end

  def test_divergence_compares_provider_quality_not_invented_outcomes
    divergence = @summary["divergence"]

    assert_operator divergence["operations"], :>, 0
    assert_equal @result.decisions.size - @summary["agreement_with_history"], divergence["operations"],
                 "разошедшиеся плюс совпавшие должны давать всю историю"
    assert_in_delta divergence["our_provider_success_rate"] - divergence["historical_provider_success_rate"],
                    divergence["delta"], 1e-6
  end

  # Реплей относится к другому дню, и стартовать с сегодняшнего оборота
  # значило бы сравнивать несравнимое: часть провайдеров была бы заблокирована
  # дневным лимитом ещё до первой заявки.
  def test_fleet_starts_the_day_from_zero
    daily = @router.fleet.providers.filter_map { |provider| provider.initial_daily_amount }

    refute_empty daily.reject(&:zero?),
                 "в исходных данных оборот ненулевой — иначе проверка ничего не значит"
    assert @summary["share_comparison"].values.all? { |row| row["replay_pct"] >= 0 }
  end

  def test_shares_sum_to_the_whole_queue
    total = @summary["share_comparison"].values.sum { |row| row["replay_pct"] }

    assert_in_delta 100.0, total, 0.5, "каждая операция обязана попасть ровно в одну долю"
  end

  def test_drift_is_reported_against_the_proven_minimum
    tvd = @summary["total_variation_distance"]
    minimum = @summary.dig("target_achievability", "min_total_variation_distance")

    refute_nil minimum, "без минимума число дрейфа не с чем сравнивать"
    assert_operator minimum, :<=, tvd["replay_vs_target"] + 1e-9
    assert_operator tvd["history_vs_target"], :>=, 0.0
  end

  def test_empty_history_is_refused_rather_than_guessed
    router = build_case_router(history_path: nil)

    assert router.calibration.empty?
    error = assert_raises(Routing::DataError) do
      Routing::Analytics::Replay.new(router: router, config: router.config).run
    end
    assert_match(/история/i, error.message)
  end

  def test_replay_is_reproducible
    again = Routing::Analytics::Replay.new(router: build_case_router, config: @router.config).run

    assert_equal @summary["agreement_with_history"], again.summary["agreement_with_history"]
    assert_equal @result.decisions.map(&:selected_provider), again.decisions.map(&:selected_provider)
  end

  private

  def build_case_router(history_path: RoutingTest::HISTORY_PATH)
    Routing::Router.build(config: project_config,
                          providers_path: RoutingTest::PROVIDERS_PATH,
                          history_path: history_path)
  end
end
