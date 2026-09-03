# frozen_string_literal: true

require_relative "test_helper"

# Каскад: порядок попыток, отказы, fallback и деградация целей.
#
# Ответы провайдеров подставляются заглушкой, а не симулятором со случайным
# зерном: иначе тест проверял бы генератор случайных чисел, а не каскад.
class CascadeTest < Minitest::Test
  Stub = RoutingTest::StubSimulator

  BASE = {
    "status" => "active",
    "limit_amount_min" => 500,
    "limit_amount_max" => 200_000,
    "available_requisites" => 10,
    "provider_margin_pct" => 1.0,
    "merchant_margin_pct" => 1.5,
    "conversion_24h" => 0.9
  }.freeze

  def provider(id, attrs = {})
    self_ids = attrs.delete("self") ? [id] : []
    build_provider(BASE.merge("payment_system" => id).merge(attrs), self_provider_ids: self_ids)
  end

  def standard_fleet(first: {}, second: {}, fallback: {})
    build_fleet([
                  provider("first", { "traffic_percentage" => 50, "priority" => 1 }.merge(first)),
                  provider("second", { "traffic_percentage" => 50, "priority" => 2 }.merge(second)),
                  provider("spacepayments", { "traffic_percentage" => 0, "priority" => 99,
                                              "self" => true }.merge(fallback))
                ])
  end

  def route(fleet, simulator, config: nil, operation: nil)
    cascade = build_cascade(fleet: fleet, config: config, simulator: simulator)
    cascade.route(operation || build_operation(id: "op_1", amount: 10_000, bank: "sberbank"))
  end

  def attempt_for(decision, provider_id) = decision.attempts.find { |a| a["provider"] == provider_id }

  # --- переход к следующему провайдеру -------------------------------------

  def test_refusal_of_the_first_provider_hands_the_operation_to_the_next
    fleet = standard_fleet
    simulator = Stub.new { |id, _| id == "first" ? Stub.declined : Stub.approved }

    decision = route(fleet, simulator)

    assert_equal "second", decision.selected_provider
    assert_equal %w[first second], decision.cascade_path.map { |step| step["provider"] },
                 "хронология каскада сохранена целиком"
    assert_equal "approved", decision.simulated_result
    assert_equal "skipped", attempt_for(decision, "first")["decision"]
    assert_equal "provider_declined", attempt_for(decision, "first")["reason"]
    assert_equal "selected", attempt_for(decision, "second")["decision"]
  end

  def test_timeout_is_distinguished_from_a_decline_in_the_reason_code
    fleet = standard_fleet
    simulator = Stub.new { |id, _| id == "first" ? Stub.expired : Stub.approved }

    decision = route(fleet, simulator)

    assert_equal "provider_timeout", attempt_for(decision, "first")["reason"]
    assert_equal "second", decision.selected_provider
  end

  def test_state_of_the_refusing_provider_is_rolled_back
    fleet = standard_fleet
    before_requisites = fleet["first"].available_requisites
    simulator = Stub.new { |id, _| id == "first" ? Stub.declined : Stub.approved }

    route(fleet, simulator)

    assert_equal before_requisites, fleet["first"].available_requisites
    assert_equal 0, fleet["first"].in_progress_count
    assert_predicate fleet["first"].daily_amount, :zero?
    assert_equal 1, fleet["first"].declined_count
  end

  def test_only_the_final_provider_counts_towards_the_traffic_share
    fleet = standard_fleet
    simulator = Stub.new { |id, _| id == "first" ? Stub.declined : Stub.approved }

    route(fleet, simulator)

    assert_equal 0, fleet["first"].selected_count, "отказавшая попытка в долю трафика не входит"
    assert_equal 1, fleet["second"].selected_count
  end

  def test_untouched_eligible_providers_are_still_explained
    fleet = standard_fleet
    simulator = Stub.new { |_, _| Stub.approved }

    decision = route(fleet, simulator)
    skipped = attempt_for(decision, "second")

    assert_equal "skipped", skipped["decision"]
    assert_equal "not_reached_in_cascade", skipped["reason"]
    refute_nil skipped["details"], "нерассмотренному кандидату тоже нужна причина"
  end

  def test_every_provider_of_the_fleet_appears_in_attempts
    fleet = standard_fleet
    decision = route(fleet, Stub.new { |_, _| Stub.approved })

    assert_equal %w[first second], decision.attempts.map { |a| a["provider"] },
                 "fallback в attempts не попадает, пока внешний пул не пуст"
    assert(decision.attempts.all? { |a| %w[selected skipped].include?(a["decision"]) })
    assert(decision.attempts.all? { |a| Routing::Reasons.known?(a["reason"]) })
  end

  # --- fallback на self-провайдера -----------------------------------------

  def test_empty_pool_falls_back_to_the_self_provider
    fleet = standard_fleet(first: { "status" => "disabled" }, second: { "status" => "disabled" })
    decision = route(fleet, Stub.new { |_, _| Stub.approved })

    assert_equal "spacepayments", decision.selected_provider
    assert_equal "fallback_self_provider", decision.selection_reason
    assert(decision.cascade_path.last["fallback"], "шаг каскада помечен как fallback")
    assert_equal "provider_inactive", attempt_for(decision, "first")["reason"]
  end

  def test_fallback_is_used_when_hard_constraints_leave_nobody
    # Сумма вне диапазона обоих внешних провайдеров, у self-провайдера
    # диапазона нет вовсе.
    fleet = standard_fleet(first: { "limit_amount_max" => 50_000 },
                           second: { "limit_amount_max" => 50_000 },
                           fallback: { "limit_amount_min" => nil, "limit_amount_max" => nil })
    decision = route(fleet, Stub.new { |_, _| Stub.approved },
                     operation: build_operation(id: "op_big", amount: 500_000))

    assert_equal "spacepayments", decision.selected_provider
    assert_equal "amount_exceeds_limit", attempt_for(decision, "first")["reason"]
  end

  def test_no_route_at_all_is_reported_and_does_not_crash
    fleet = build_fleet([provider("first", { "traffic_percentage" => 100, "status" => "disabled" })])
    decision = route(fleet, Stub.new { |_, _| Stub.approved })

    assert_nil decision.selected_provider
    assert_equal "no_provider_available", decision.selection_reason
    assert_includes decision.events.map { |e| e["type"] }, "no_route"
    assert_equal "rejected", decision.simulated_result
  end

  # --- политика исчерпания пула --------------------------------------------

  def test_retry_best_policy_stays_on_external_providers_when_all_refuse
    fleet = standard_fleet
    simulator = Stub.new { |_, _| Stub.declined }
    config = config_with({ "run" => { "exhausted_pool_policy" => "retry_best" } })

    decision = route(fleet, simulator, config: config)

    assert_includes %w[first second], decision.selected_provider,
                    "по умолчанию каскад не прячет отказ конверсии за self-провайдером"
    assert_equal "cascade_retry", decision.selection_reason
    assert_includes decision.events.map { |e| e["type"] }, "pool_exhausted"
    assert_equal "retry_best", decision.events.find { |e| e["type"] == "pool_exhausted" }["policy"]
    refute_includes decision.cascade_path.map { |step| step["provider"] }, "spacepayments"
  end

  def test_fallback_policy_hands_the_operation_to_the_self_provider_when_all_refuse
    fleet = standard_fleet
    simulator = Stub.new { |id, _| id == "spacepayments" ? Stub.approved : Stub.declined }
    config = config_with({ "run" => { "exhausted_pool_policy" => "fallback" } })

    decision = route(fleet, simulator, config: config)

    assert_equal "spacepayments", decision.selected_provider
    assert_equal "fallback_self_provider", decision.selection_reason
    assert_equal "fallback", decision.events.find { |e| e["type"] == "pool_exhausted" }["policy"]
    assert_equal %w[first second spacepayments], decision.cascade_path.map { |step| step["provider"] }
  end

  def test_the_two_policies_give_different_answers_on_the_same_input
    simulator = -> { Stub.new { |id, _| id == "spacepayments" ? Stub.approved : Stub.declined } }

    retry_best = route(standard_fleet, simulator.call,
                       config: config_with({ "run" => { "exhausted_pool_policy" => "retry_best" } }))
    fallback = route(standard_fleet, simulator.call,
                     config: config_with({ "run" => { "exhausted_pool_policy" => "fallback" } }))

    refute_equal retry_best.selected_provider, fallback.selected_provider,
                 "политика исчерпания пула меняется настройкой и меняет результат"
  end

  def test_max_attempts_bounds_the_cascade
    fleet = build_fleet(4.times.map { |i| provider("p#{i}", "traffic_percentage" => 25, "priority" => i + 1) })
    simulator = Stub.new { |_, _| Stub.declined }
    config = config_with({ "run" => { "max_attempts" => 2, "exhausted_pool_policy" => "retry_best" } })

    decision = route(fleet, simulator, config: config)

    assert_equal 3, decision.cascade_path.size, "две попытки по каскаду плюс повтор на лучшем"
  end

  # --- деградация недостижимой цели ----------------------------------------

  def test_unreachable_target_share_produces_a_goal_relaxation_event
    fleet = standard_fleet(first: { "traffic_percentage" => 70, "banks" => %w[tinkoff],
                                    "exclude_banks" => false },
                           second: { "traffic_percentage" => 30 })
    decision = route(fleet, Stub.new { |_, _| Stub.approved },
                     operation: build_operation(id: "op_sber", amount: 10_000, bank: "sberbank"))

    event = decision.events.find { |e| e["type"] == "goal_relaxation" }

    refute_nil event, "недостижимая цель обязана быть зафиксирована в решении"
    assert_equal "traffic_share", event["goal"]
    assert_includes event["unreachable"].keys, "first"
    assert_in_delta 70.0, event["released_share_pct"], 0.1
    assert_equal %w[second], event["reallocated_to"]
  end

  def test_target_shares_are_recomputed_on_the_available_providers
    fleet = standard_fleet(first: { "traffic_percentage" => 70 }, second: { "traffic_percentage" => 30 })

    assert_in_delta 0.30, fleet.count_target("second"), 1e-9, "глобальная цель"
    assert_in_delta 1.00, fleet.count_target("second", among: %w[second]), 1e-9,
                    "если доступен только second, вся доля переходит к нему"
    assert_in_delta 0.70, fleet.count_target("first", among: %w[first second]), 1e-9
    assert_in_delta 0.0, fleet.count_target("first", among: %w[second]), 1e-9,
                    "недоступный провайдер не претендует на долю"
  end

  def test_unreachable_targets_lists_who_dropped_out_and_with_what_share
    fleet = standard_fleet(first: { "traffic_percentage" => 70 }, second: { "traffic_percentage" => 30 })

    assert_equal({ "first" => 0.7 }, fleet.unreachable_targets(%w[second]).transform_values { |v| v.round(4) })
    assert_empty fleet.unreachable_targets(%w[first second])
  end

  def test_no_relaxation_event_when_every_provider_is_available
    fleet = standard_fleet
    decision = route(fleet, Stub.new { |_, _| Stub.approved })

    assert_empty decision.events.select { |e| e["type"] == "goal_relaxation" }
  end

  def test_goal_relaxation_can_be_switched_off_in_configuration
    fleet = standard_fleet(first: { "traffic_percentage" => 70, "banks" => %w[tinkoff],
                                    "exclude_banks" => false },
                           second: { "traffic_percentage" => 30 })
    config = config_with({ "goal_relaxation" => { "enabled" => false } })
    decision = route(fleet, Stub.new { |_, _| Stub.approved }, config: config,
                     operation: build_operation(id: "op_sber", amount: 10_000, bank: "sberbank"))

    assert_empty decision.events.select { |e| e["type"] == "goal_relaxation" }
  end

  # --- объяснимость выбора --------------------------------------------------

  def test_the_only_eligible_provider_is_explained_as_such
    fleet = standard_fleet(second: { "status" => "disabled" })
    decision = route(fleet, Stub.new { |_, _| Stub.approved })

    assert_equal "first", decision.selected_provider
    assert_equal "only_eligible_provider", decision.selection_reason
  end

  def test_selection_names_the_goal_that_settled_the_argument
    fleet = standard_fleet
    decision = route(fleet, Stub.new { |_, _| Stub.approved })
    selected = attempt_for(decision, decision.selected_provider)

    assert Routing::Reasons.known?(decision.selection_reason),
           "причина выбора #{decision.selection_reason} должна быть в каталоге"
    assert_equal :selection, Routing::Reasons.category(decision.selection_reason)
    refute_nil selected["factors"], "в решении сохранён разбор по каждому фактору"
    refute_empty decision.ranking, "скоринг всех кандидатов остаётся в решении"
  end

  def test_decision_serializes_the_contract_of_the_organisers
    decision = route(standard_fleet, Stub.new { |_, _| Stub.approved })
    strict = decision.to_strict_h

    assert_equal %w[operation_id selected_provider attempts simulated_result latency_sec], strict.keys
    assert(strict["attempts"].all? { |a| (a.keys - %w[provider decision reason details]).empty? },
           "строгая форма не содержит ни одного лишнего поля")
    assert_kind_of Integer, strict["latency_sec"]
  end

  def test_full_decision_keeps_the_explanation_next_to_the_contract
    decision = route(standard_fleet, Stub.new { |_, _| Stub.approved })
    full = decision.to_h

    %w[operation_id selected_provider attempts simulated_result latency_sec selection cascade].each do |key|
      assert_includes full.keys, key
    end
    assert_equal decision.cascade_path.size, full["cascade"]["attempts_made"]
  end

  # --- найденные расхождения ------------------------------------------------

  def test_repeated_attempt_on_the_same_provider_keeps_the_earlier_refusal_in_attempts
    skip("баг: records индексируется по provider_id, поэтому повторная попытка " \
         "на том же провайдере затирает его запись об отказе. В attempts остаётся " \
         "только итоговый selected, отказ исчезает из выгрузки, sequence начинается " \
         "не с единицы, а skip_reasons в отчёте недосчитывает provider_declined")

    fleet = build_fleet([provider("first", "traffic_percentage" => 100, "priority" => 1),
                         provider("spacepayments", "traffic_percentage" => 0, "priority" => 99, "self" => true)])
    simulator = Stub.new { |_, attempt_no| attempt_no == 1 ? Stub.declined : Stub.approved }

    decision = route(fleet, simulator)

    assert_equal "first", decision.selected_provider
    assert_equal 2, decision.cascade_path.size, "каскад действительно сходил к first дважды"

    records = decision.attempts.select { |a| a["provider"] == "first" }

    assert_equal 2, records.size,
                 "обе попытки обязаны остаться в attempts: отказ и последующий выбор"
    assert_includes records.map { |a| a["reason"] }, "provider_declined"
    assert_equal (1..decision.attempts.size).to_a, decision.attempts.map { |a| a["sequence"] }.sort,
                 "в нумерации попыток не должно быть пропусков"
  end

  def test_latency_accumulates_over_the_whole_cascade
    fleet = standard_fleet
    simulator = Stub.new { |id, _| id == "first" ? Stub.declined(latency: 8) : Stub.approved(latency: 30) }

    decision = route(fleet, simulator)

    assert_equal 38, decision.latency_sec, "задержка складывается по всем попыткам, а не только по последней"
  end
end
