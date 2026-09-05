# frozen_string_literal: true

require_relative "test_helper"

# Мягкие цели: по одному разделу на каждую из восьми.
#
# Проверяется не абсолютная величина raw_score — она в своих единицах у каждой
# цели и сравнивать её между целями нельзя, — а упорядочивание провайдеров
# в понятной ситуации: кого цель поставит выше и почему.
class StrategiesTest < Minitest::Test
  S = Routing::Strategies

  BASE = {
    "status" => "active",
    "limit_amount_min" => 500,
    "limit_amount_max" => 200_000,
    "available_requisites" => 10,
    "provider_margin_pct" => 1.0,
    "merchant_margin_pct" => 1.5
  }.freeze

  def pair(left_attrs, right_attrs, operation: {}, at: 1000.0)
    left = build_provider(BASE.merge("payment_system" => "left").merge(left_attrs))
    right = build_provider(BASE.merge("payment_system" => "right").merge(right_attrs))
    fleet = build_fleet([left, right])
    operation = build_operation(**{ amount: 10_000 }.merge(operation))
    contexts = [left, right].map do |provider|
      context_for(provider: provider, operation: operation, fleet: fleet, at: at, eligible_ids: %w[left right])
    end
    [fleet, contexts.first, contexts.last]
  end

  # Провайдер, чья цель сильнее не выполнена, должен получить больший raw_score.
  def assert_prefers(strategy, better_context, worse_context, message = nil)
    better = strategy.raw_score(better_context)
    worse = strategy.raw_score(worse_context)

    refute_nil better, "цель #{strategy.id} не смогла оценить предпочтительного кандидата"
    refute_nil worse, "цель #{strategy.id} не смогла оценить второго кандидата"
    assert_operator better, :>, worse,
                    message || "#{strategy.id}: ожидалось #{better_context.id} > #{worse_context.id}"
  end

  # --- цена заявки для партнёра --------------------------------------------

  # Лимит задан в деньгах, доля — в заявках. Крупный чек, отданный партнёру
  # с узким остатком, стоит ему нескольких заявок собственной доли.
  def test_headroom_fit_prefers_the_provider_for_whom_the_operation_is_cheaper
    _, tight, roomy = pair({ "daily_amount_limit" => 100_000, "daily_approved_amount" => 0 },
                           { "daily_amount_limit" => 5_000_000, "daily_approved_amount" => 0 },
                           operation: { amount: 47_000 })

    assert_prefers(S::HeadroomFit.new, roomy, tight,
                   "47 000 — половина остатка у первого и процент у второго")
  end

  def test_headroom_fit_says_nothing_when_there_is_no_daily_limit
    _, without, _with = pair({}, { "daily_amount_limit" => 1_000_000 })

    assert_nil S::HeadroomFit.new.raw_score(without),
               "без дневного лимита сравнивать нечего — цель обязана промолчать"
    assert_match(/запас неограничен/, S::HeadroomFit.new.explain(without))
  end

  # Величина у этой цели имеет собственный смысл: 0.47 — «половина остатка».
  # Нормализация по кандидатам растянула бы разницу в три процента до максимума.
  def test_headroom_fit_is_measured_on_its_own_scale
    assert S::HeadroomFit.new.absolute?, "доля запаса — готовая шкала 0..1"
    refute S::CountShare.new.absolute?, "заявки недобора — не шкала 0..1"
  end

  def test_absolute_scale_survives_the_scorer_untouched
    _, tight, roomy = pair({ "daily_amount_limit" => 100_000, "daily_approved_amount" => 0 },
                           { "daily_amount_limit" => 5_000_000, "daily_approved_amount" => 0 },
                           operation: { amount: 50_000 })
    scorer = Routing::Scorer.new([S::HeadroomFit.new("weight" => 1.0, "tier" => 2)],
                                 Routing::Config.new(Routing::Config::DEFAULTS))
    ranked = scorer.rank([tight, roomy])
    values = ranked.to_h { |row| [row.provider_id, row.contributions.first.normalized] }

    assert_in_delta 0.5, values["left"], 1e-6, "половина остатка обязана остаться половиной"
    assert_operator values["right"], :>, 0.98, "процент остатка обязан остаться процентом"
  end

  # --- 1. доля по количеству заявок ----------------------------------------

  def test_count_share_prefers_the_provider_with_the_bigger_deficit
    fleet, left, right = pair({ "traffic_percentage" => 50 }, { "traffic_percentage" => 50 })
    2.times { |i| fleet["left"].record_selection(build_operation(id: "seen_#{i}", amount: 1000)) }

    strategy = S::CountShare.new({})

    assert_prefers strategy, right, left,
                   "left уже забрал обе заявки при равных целях — предпочтение уходит к right"
    assert_in_delta 1.5, strategy.raw_score(right)
    assert_in_delta(-0.5, strategy.raw_score(left))
  end

  def test_count_share_follows_the_configured_target_not_the_current_count
    # Одна и та же история распределения, разные цели — разный ответ.
    generous, left_generous, right_generous = pair({ "traffic_percentage" => 80 },
                                                   { "traffic_percentage" => 20 })
    generous["left"].record_selection(build_operation(id: "seen", amount: 1000))

    strict, left_strict, right_strict = pair({ "traffic_percentage" => 20 },
                                             { "traffic_percentage" => 80 })
    strict["left"].record_selection(build_operation(id: "seen", amount: 1000))

    strategy = S::CountShare.new({})

    assert_prefers strategy, left_generous, right_generous,
                   "при цели 80% одна выданная заявка ещё не выбирает долю left"
    assert_prefers strategy, right_strict, left_strict,
                   "при цели 20% та же самая заявка уже перевыполняет долю left"
  end

  def test_count_share_is_not_applicable_to_a_provider_without_a_target
    fleet, left, = pair({ "traffic_percentage" => 0 }, { "traffic_percentage" => 100 })

    assert_nil S::CountShare.new({}).raw_score(left)
    refute_nil fleet
  end

  def test_count_share_explains_itself_in_words
    fleet, left, = pair({ "traffic_percentage" => 50 }, { "traffic_percentage" => 50 })
    strategy = S::CountShare.new({})

    assert_match(/по количеству/, strategy.explain(left))
    assert_match(/50/, strategy.explain(left), "в объяснении должна стоять целевая доля")

    fleet["right"].record_selection(build_operation(id: "seen", amount: 1000))

    assert_match(/по количеству/, strategy.explain(left))
    assert_match(/недобор/, strategy.explain(left))
  end

  # --- 2. доля по объёму ----------------------------------------------------

  def test_volume_share_prefers_the_provider_lagging_in_money
    fleet, left, right = pair({ "traffic_percentage" => 50, "volume_share_pct" => 50 },
                              { "traffic_percentage" => 50, "volume_share_pct" => 50 })
    fleet["left"].record_selection(build_operation(id: "big", amount: 100_000))

    assert_prefers S::VolumeShare.new({}), right, left,
                   "объём считается в рублях: одна крупная заявка перекрывает долю целиком"
  end

  def test_volume_share_differs_from_count_share_on_the_same_history
    fleet, left, right = pair({ "traffic_percentage" => 50, "volume_share_pct" => 50 },
                              { "traffic_percentage" => 50, "volume_share_pct" => 50 })
    # left взял одну крупную заявку, right — три мелких.
    fleet["left"].record_selection(build_operation(id: "big", amount: 300_000))
    3.times { |i| fleet["right"].record_selection(build_operation(id: "small_#{i}", amount: 1000)) }

    count = S::CountShare.new({})
    volume = S::VolumeShare.new({})

    assert_operator count.raw_score(left), :>, count.raw_score(right),
                    "по количеству отстал left"
    assert_operator volume.raw_score(right), :>, volume.raw_score(left),
                    "по объёму отстал right — цели указывают на разных, это и разводит Scorer"
  end

  def test_volume_share_is_not_applicable_without_a_target
    _fleet, left, = pair({ "traffic_percentage" => 0, "volume_share_pct" => 0 },
                         { "traffic_percentage" => 100, "volume_share_pct" => 100 })

    assert_nil S::VolumeShare.new({}).raw_score(left)
  end

  # --- 3. конверсия ---------------------------------------------------------

  def test_conversion_prefers_the_higher_declared_conversion
    _fleet, left, right = pair({ "conversion_24h" => 0.91 }, { "conversion_24h" => 0.79 })

    assert_prefers S::Conversion.new({}), left, right
  end

  def test_conversion_in_raw_mode_returns_the_declared_value_as_is
    _fleet, left, = pair({ "conversion_24h" => 0.91 }, { "conversion_24h" => 0.79 })

    assert_in_delta 0.91, S::Conversion.new({ "estimator" => "raw" }).raw_score(left)
  end

  def test_conversion_lowers_a_provider_that_just_declined
    fleet, left, right = pair({ "conversion_24h" => 0.9 }, { "conversion_24h" => 0.9 })
    strategy = S::Conversion.new({ "prior_weight" => 20, "confidence" => 0.95 })
    before = strategy.raw_score(left)

    3.times do |i|
      operation = build_operation(id: "fail_#{i}", amount: 1000)
      fleet["left"].reserve(operation, at: 1000.0 + i)
      fleet["left"].settle_failed(operation, :rejected)
    end

    assert_operator strategy.raw_score(left), :<, before,
                    "три отказа подряд должны опустить оценку сразу, а не после набора выборки"
    assert_prefers strategy, right, left
  end

  def test_conversion_uses_the_lower_bound_so_a_small_sample_does_not_win
    strategy = S::Conversion.new({ "prior_weight" => 0, "confidence" => 0.95 })
    fleet, left, right = pair({ "conversion_24h" => nil }, { "conversion_24h" => nil })

    3.times do |i|
      operation = build_operation(id: "l_#{i}", amount: 1000)
      fleet["left"].reserve(operation, at: 1000.0 + i)
      fleet["left"].settle_approved(operation)
    end
    100.times do |i|
      operation = build_operation(id: "r_#{i}", amount: 1000)
      fleet["right"].reserve(operation, at: 1000.0 + i)
      i < 90 ? fleet["right"].settle_approved(operation) : fleet["right"].settle_failed(operation, :rejected)
    end

    assert_in_delta 1.0, fleet["left"].observed_conversion
    assert_in_delta 0.9, fleet["right"].observed_conversion
    assert_prefers strategy, right, left,
                   "90 из 100 надёжнее, чем 3 из 3, хотя сырая конверсия у второго выше"
  end

  # --- 4. диапазон суммы как предпочтение ----------------------------------

  def test_amount_band_prefers_the_provider_listed_for_the_band
    strategy = S::AmountBand.new({ "bands" => [{ "min" => 100_001, "max" => nil,
                                                 "prefer" => %w[left], "preference" => 1.0, "penalty" => 0.5 }] })
    _fleet, left, right = pair({}, {}, operation: { amount: 150_000 })

    assert_prefers strategy, left, right
    assert_match(/предпочтителен/, strategy.explain(left))
    assert_match(/не в списке/, strategy.explain(right))
  end

  def test_amount_band_is_neutral_when_the_amount_matches_no_band
    strategy = S::AmountBand.new({ "bands" => [{ "min" => 1, "max" => 100, "prefer" => %w[left] }] })
    _fleet, left, right = pair({}, {}, operation: { amount: 150_000 })

    assert_in_delta S::AmountBand::NEUTRAL, strategy.raw_score(left)
    assert_in_delta S::AmountBand::NEUTRAL, strategy.raw_score(right)
  end

  def test_amount_band_without_bands_prefers_the_more_specialised_range
    strategy = S::AmountBand.new({})
    _fleet, left, right = pair({ "limit_amount_min" => 50_000, "limit_amount_max" => 100_000 },
                               { "limit_amount_min" => 500, "limit_amount_max" => 1_000_000 },
                               operation: { amount: 60_000 })

    assert_prefers strategy, left, right,
                   "узкий диапазон вокруг суммы — признак специализации, широкий — универсальности"
  end

  def test_amount_band_is_not_applicable_to_a_provider_without_a_range
    strategy = S::AmountBand.new({})
    provider = build_provider({ "payment_system" => "open", "status" => "active", "traffic_percentage" => 10 })
    fleet = build_fleet([provider])
    context = context_for(provider: provider, operation: build_operation, fleet: fleet)

    assert_nil strategy.raw_score(context)
    assert_match(/не задан/, strategy.explain(context))
  end

  def test_amount_band_is_a_preference_and_not_a_hard_limit
    # Диапазон провайдера не отсекает — отсечение делает AmountRange.
    # Здесь тот же диапазон только меняет предпочтение.
    strategy = S::AmountBand.new({})
    _fleet, left, right = pair({ "limit_amount_max" => 200_000 }, { "limit_amount_max" => 1_000_000 },
                               operation: { amount: 150_000 })

    refute_nil strategy.raw_score(left)
    refute_nil strategy.raw_score(right)
  end

  # --- 5. очередь в каскаде -------------------------------------------------

  def test_cascade_priority_prefers_the_smaller_priority_number
    _fleet, left, right = pair({ "priority" => 1 }, { "priority" => 3 })

    assert_prefers S::CascadePriority.new({}), left, right
    assert_match(/приоритет в каскаде 1/, S::CascadePriority.new({}).explain(left))
  end

  def test_cascade_priority_sends_provider_without_priority_to_the_end
    strategy = S::CascadePriority.new({})
    _fleet, left, right = pair({ "priority" => 99 }, {})

    assert_prefers strategy, left, right
    assert_in_delta(-S::CascadePriority::UNRANKED.to_f, strategy.raw_score(right))
    assert_match(/не задан/, strategy.explain(right))
  end

  def test_cascade_priority_default_is_configurable
    strategy = S::CascadePriority.new({ "default_priority" => 5 })
    _fleet, _left, right = pair({ "priority" => 1 }, {})

    assert_in_delta(-5.0, strategy.raw_score(right))
  end

  # --- 6. загрузка ----------------------------------------------------------

  def test_load_balance_prefers_the_less_loaded_provider
    _fleet, left, right = pair({ "daily_amount_limit" => 5_000_000, "daily_approved_amount" => 1_000_000 },
                               { "daily_amount_limit" => 5_000_000, "daily_approved_amount" => 4_500_000 })

    assert_prefers S::LoadBalance.new({}), left, right
    assert_in_delta 0.8, S::LoadBalance.new({}).raw_score(left), 0.001
    assert_in_delta 0.1, S::LoadBalance.new({}).raw_score(right), 0.001
  end

  def test_load_balance_takes_the_worst_measure_not_the_average
    # Дневной оборот у обоих пуст, но у right почти кончились реквизиты.
    # Среднее по измерениям это бы замаскировало, максимум — нет.
    fleet, left, right = pair({ "daily_amount_limit" => 5_000_000, "available_requisites" => 10 },
                              { "daily_amount_limit" => 5_000_000, "available_requisites" => 10 })
    9.times { |i| fleet["right"].reserve(build_operation(id: "hold_#{i}", amount: 100), at: 1000.0 + i) }

    assert_in_delta 0.0, fleet["right"].daily_utilization
    assert_in_delta 0.9, fleet["right"].requisite_utilization, 0.001
    assert_prefers S::LoadBalance.new({}), left, right
  end

  def test_load_balance_explains_the_bottleneck
    _fleet, left, = pair({ "daily_amount_limit" => 5_000_000, "daily_approved_amount" => 4_500_000 }, {})

    assert_match(/узкое место/, S::LoadBalance.new({}).explain(left))
  end

  # --- 7. обязательства по обороту -----------------------------------------
  #
  # Цель считает не сам недобор, а темп, которого он требует от остатка суток:
  # «не добрано 2 млн» в девять утра и в одиннадцать вечера — разные ситуации.
  # Поэтому во всех проверках задаётся конкретное время заявки.

  MORNING = Time.new(2026, 7, 30, 9, 0, 0).to_f
  LATE_EVENING = Time.new(2026, 7, 30, 22, 0, 0).to_f

  def test_turnover_commitment_prefers_the_provider_further_from_its_minimum
    _fleet, left, right = pair({ "daily_turnover_min" => 2_000_000, "daily_approved_amount" => 0 },
                               { "daily_turnover_min" => 2_000_000, "daily_approved_amount" => 1_800_000 },
                               at: LATE_EVENING)

    assert_prefers S::TurnoverCommitment.new({}), left, right
  end

  def test_turnover_commitment_stays_out_of_the_way_while_the_provider_is_on_schedule
    strategy = S::TurnoverCommitment.new({})
    _fleet, left, = pair({ "daily_turnover_min" => 2_000_000, "daily_approved_amount" => 1_800_000 }, {},
                         at: MORNING)

    assert_in_delta 0.0, strategy.raw_score(left), 1e-9,
                    "утром недобор в 10% — это график, а не срыв: старший эшелон остаётся ничейным"
    assert_match(/график/, strategy.explain(left))
  end

  def test_turnover_commitment_wakes_up_when_the_day_is_running_out
    strategy = S::TurnoverCommitment.new({})
    _fleet, morning, = pair({ "daily_turnover_min" => 2_000_000, "daily_approved_amount" => 0 }, {},
                            at: MORNING)
    _fleet2, evening, = pair({ "daily_turnover_min" => 2_000_000, "daily_approved_amount" => 0 }, {},
                             at: LATE_EVENING)

    assert_operator strategy.raw_score(evening), :>, strategy.raw_score(morning),
                    "тот же недобор к вечеру требует большего темпа и поднимает провайдера выше"
  end

  def test_turnover_commitment_is_silent_once_the_minimum_is_met
    strategy = S::TurnoverCommitment.new({})
    _fleet, left, = pair({ "daily_turnover_min" => 1_000_000, "daily_approved_amount" => 1_500_000 }, {},
                         at: LATE_EVENING)

    assert_in_delta 0.0, strategy.raw_score(left)
    assert_match(/выполнен/, strategy.explain(left))
  end

  def test_turnover_commitment_is_not_applicable_without_the_obligation
    strategy = S::TurnoverCommitment.new({})
    _fleet, _left, right = pair({ "daily_turnover_min" => 1_000_000 }, {}, at: LATE_EVENING)

    assert_nil strategy.raw_score(right)
    assert_match(/не задано/, strategy.explain(right))
  end

  def test_turnover_commitment_urgency_exponent_is_configurable
    gentle = S::TurnoverCommitment.new({ "urgency_exponent" => 2.0 })
    steep = S::TurnoverCommitment.new({ "urgency_exponent" => 0.5 })
    _fleet, left, = pair({ "daily_turnover_min" => 1_000_000, "daily_approved_amount" => 900_000 }, {},
                         at: LATE_EVENING)

    assert_operator steep.raw_score(left), :>, gentle.raw_score(left),
                    "меньший показатель степени делает цель настойчивее при малом отставании"
  end

  def test_turnover_commitment_activation_threshold_is_configurable
    _fleet, left, = pair({ "daily_turnover_min" => 2_000_000, "daily_approved_amount" => 1_800_000 }, {},
                         at: MORNING)

    assert_in_delta 0.0, S::TurnoverCommitment.new({}).raw_score(left)
    assert_operator S::TurnoverCommitment.new({ "activation_pressure" => 0.05 }).raw_score(left), :>, 0.0,
                    "порог включения задаётся настройкой, а не зашит в код"
  end

  # --- 8. маржинальность ----------------------------------------------------

  def test_margin_prefers_the_provider_that_leaves_more_to_the_merchant
    _fleet, left, right = pair({ "provider_margin_pct" => 0.8, "merchant_margin_pct" => 1.5 },
                               { "provider_margin_pct" => 1.2, "merchant_margin_pct" => 1.5 })

    assert_prefers S::Margin.new({}), left, right
    assert_in_delta 0.7, S::Margin.new({}).raw_score(left), 1e-9
  end

  def test_margin_falls_back_to_provider_fee_when_merchant_margin_is_unknown
    strategy = S::Margin.new({})
    left = build_provider({ "payment_system" => "left", "status" => "active",
                            "traffic_percentage" => 50, "provider_margin_pct" => 0.5 })
    right = build_provider({ "payment_system" => "right", "status" => "active",
                             "traffic_percentage" => 50, "provider_margin_pct" => 2.0 })
    fleet = build_fleet([left, right])
    operation = build_operation
    contexts = [left, right].map { |p| context_for(provider: p, operation: operation, fleet: fleet) }

    assert_prefers strategy, contexts.first, contexts.last
    assert_match(/маржа мерчанта не задана/, strategy.explain(contexts.first))
  end

  # --- реестр целей ---------------------------------------------------------

  def test_registry_knows_all_eight_routing_goals
    expected = %w[amount_band cascade_priority conversion count_share
                  load_balance margin turnover_commitment volume_share]

    assert_equal expected, (expected & S::Registry.known_ids).sort
    assert_equal 8, expected.size
  end

  def test_registry_builds_goals_declared_in_configuration
    built = S::Registry.build(project_config)

    assert_equal project_config.enabled_strategy_ids.sort, built.map(&:id).sort
    assert(built.all? { |strategy| strategy.weight.positive? })
  end

  def test_registry_refuses_unknown_goal_names
    config = config_with({ "strategies" => { "astrology" => { "enabled" => true } } })
    error = assert_raises(Routing::ConfigError) { S::Registry.build(config) }

    assert_match(/astrology/, error.message)
  end

  def test_every_goal_maps_to_a_selection_reason_from_the_catalog
    S::Registry.build(project_config).each do |strategy|
      reason = strategy.selection_reason

      assert Routing::Reasons.known?(reason),
             "цель #{strategy.id} представляется причиной #{reason}, которой нет в каталоге"
      assert_equal :selection, Routing::Reasons.category(reason)
    end
  end

  def test_base_goal_demands_an_implementation
    assert_raises(NotImplementedError) { S::Base.new.raw_score(nil) }
  end
end
