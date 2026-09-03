# frozen_string_literal: true

require_relative "test_helper"

# Достижимость целевых долей.
#
# На этом расчёте держится главное утверждение защиты: «минимальное отклонение
# от целей 5.0 п.п., и мы попадаем ровно в него». Утверждение сильное, поэтому
# проверяется и на кейсовых данных, и на искусственных, где ответ известен
# заранее и считается в уме.
class AchievabilityTest < Minitest::Test
  include RoutingTest

  # --- кейсовые данные ----------------------------------------------------

  def test_case_data_corridors_match_the_known_values
    result = analyse_case_data

    assert_in_delta 30.0, result.dig("bounds", "quickpay", "floor_pct"), 0.01,
                    "quickpay единственный допустимый ровно в трёх заявках из десяти"
    assert_in_delta 90.0, result.dig("bounds", "quickpay", "ceiling_pct"), 0.01
    assert_equal "недостижима снизу", result.dig("bounds", "quickpay", "verdict"),
                 "цель 25% ниже пола 30% — отдать ему меньше невозможно"

    assert_equal "недостижима сверху", result.dig("bounds", "payflow", "verdict"),
                 "цель 35% выше потолка: свободного дневного лимита хватает на три заявки"
    assert_equal "дневной лимит оборота", result.dig("bounds", "payflow", "binding_limit")

    assert_equal "достижима", result.dig("bounds", "vipay", "verdict")
  end

  def test_minimum_deviation_on_case_data_is_five_points
    assert_in_delta 0.05, analyse_case_data["min_total_variation_distance"], 1e-9
  end

  # Ключевая проверка на согласованность: доказанный минимум не может быть
  # больше того, что роутер реально получил. Если такое случится — расчёт
  # границы неверен, и на защите это разберут первым же вопросом.
  def test_minimum_never_exceeds_what_the_router_actually_achieved
    report = pipeline[:report]
    minimum = report.dig("target_achievability", "min_total_variation_distance")

    actual = report["distribution"]
                 .reject { |id, _| id == "spacepayments" }
                 .sum { |_, row| (row["share_pct"] - row["target_pct"]).abs } / 200.0

    assert_operator minimum, :<=, actual + 1e-9,
                    "минимум #{minimum} оказался выше фактического отклонения #{actual}"
  end

  # Регрессия. Потолок по ёмкости считался по остатку лимита ПОСЛЕ прогона,
  # и получалось «максимум три заявки» при фактически обработанных трёх и
  # нулевом остатке — потолок ниже факта. Запас должен браться на начало.
  def test_capacity_ceiling_is_measured_from_the_headroom_at_the_start
    report = pipeline[:report]
    bounds = report.dig("target_achievability", "bounds")
    counts = report["distribution"]

    bounds.each do |id, bound|
      next unless counts.key?(id)

      assert_operator bound["ceiling_pct"], :>=, counts[id]["share_pct"] - 1e-9,
                      "#{id}: потолок #{bound['ceiling_pct']}% ниже фактических #{counts[id]['share_pct']}%"
    end
  end

  def test_assumption_behind_the_corridor_travels_with_the_data
    assert_match(/fallback/, analyse_case_data["assumption"],
                 "оговорка про нарушающую допущение политику должна лежать в самом отчёте")
  end

  # --- искусственные данные, где ответ известен заранее --------------------

  def test_floor_counts_operations_where_the_provider_is_the_only_option
    # narrow берёт только tinkoff, wide — всё. Из четырёх заявок две на tinkoff:
    # для narrow это потолок, для wide — ничего обязательного.
    fleet = two_providers
    result = analyse(fleet, [
                       operation("a", 10_000, "tinkoff"), operation("b", 10_000, "tinkoff"),
                       operation("c", 10_000, "sberbank"), operation("d", 10_000, "alfa")
                     ])

    assert_in_delta 0.0, result.dig("bounds", "narrow", "floor_pct"), 0.01,
                    "wide тоже берёт tinkoff, значит обязательных заявок у narrow нет"
    assert_in_delta 50.0, result.dig("bounds", "narrow", "ceiling_pct"), 0.01
    assert_in_delta 100.0, result.dig("bounds", "wide", "ceiling_pct"), 0.01
  end

  def test_provider_that_is_sole_option_gets_a_non_zero_floor
    fleet = build_fleet([
                          build_provider({ "payment_system" => "only_tinkoff", "traffic_percentage" => 50,
                                         "banks" => ["tinkoff"], "exclude_banks" => false}),
                          build_provider({ "payment_system" => "only_alfa", "traffic_percentage" => 50,
                                         "banks" => ["alfa"], "exclude_banks" => false})
                        ])
    result = analyse(fleet, [operation("a", 5_000, "tinkoff"), operation("b", 5_000, "tinkoff"),
                             operation("c", 5_000, "alfa"), operation("d", 5_000, "alfa")])

    assert_in_delta 50.0, result.dig("bounds", "only_tinkoff", "floor_pct"), 0.01
    assert_in_delta 50.0, result.dig("bounds", "only_tinkoff", "ceiling_pct"), 0.01
    assert_equal "достижима", result.dig("bounds", "only_tinkoff", "verdict")
  end

  # Потолок по деньгам: заявок по правилам можно взять четыре, а свободного
  # лимита хватает ровно на две самые дешёвые.
  def test_capacity_ceiling_greedily_fills_the_cheapest_operations
    fleet = build_fleet([
                          build_provider({ "payment_system" => "tight", "traffic_percentage" => 100,
                                         "daily_amount_limit" => 30_000, "daily_approved_amount" => 0})
                        ])
    result = analyse(fleet, [operation("a", 10_000), operation("b", 15_000),
                             operation("c", 40_000), operation("d", 50_000)])

    assert_in_delta 50.0, result.dig("bounds", "tight", "capacity_ceiling_pct"), 0.01,
                    "10 000 + 15 000 помещается в 30 000, третья заявка уже нет"
    assert_equal "дневной лимит оборота", result.dig("bounds", "tight", "binding_limit")
  end

  def test_stateful_constraints_do_not_participate_in_structural_analysis
    used = analyse_case_data["structural_constraints"]

    %w[in_progress_limits requisites rate_limit].each do |stateful|
      refute_includes used, stateful,
                      "#{stateful} зависит от текущей загрузки и не описывает структуру"
    end
    assert_includes used, "bank_filter"
    assert_includes used, "amount_range"
  end

  def test_operations_no_provider_may_take_are_counted_separately
    fleet = build_fleet([build_provider({ "payment_system" => "narrow", "traffic_percentage" => 100,
                                          "banks" => ["tinkoff"], "exclude_banks" => false })])
    result = analyse(fleet, [operation("a", 10_000, "tinkoff"), operation("b", 10_000, "vtb")])

    assert_equal 1, result["unroutable"]
  end

  def test_empty_queue_does_not_raise
    result = analyse(two_providers, [])

    assert_equal 0, result["operations"]
    assert_empty result["bounds"]
  end

# --- три независимых нижних границы -------------------------------------

# Самая понятная граница и самая недооценённая: доля 35% от десяти заявок —
# это три с половиной заявки, а половину выплаты отправить нельзя. Отклонение
# в пять пунктов возникает здесь ещё до того, как мы вспомним хоть об одном
# ограничении.
def test_indivisible_operations_alone_make_the_target_unreachable
  floors = analyse_case_data["floors"]

  assert_in_delta 5.0, floors["rounding_pct"], 0.01,
                  "35% от десяти заявок — 3.5 заявки, целым числом этого не добиться"
end

def test_structural_and_rounding_floors_are_computed_separately
  floors = analyse_case_data["floors"]

  assert_in_delta 5.0, floors["structural_pct"], 0.01
  refute_equal floors.object_id, floors["rounding_pct"].object_id
  refute_empty floors["note"].to_s
end

# Перебор отвечает окончательно: не «не ниже чем», а «вот столько».
# На десяти заявках допустимых раскладок меньше сотни.
def test_exhaustive_search_confirms_the_bound_on_the_case_queue
  floors = analyse_case_data["floors"]

  assert_in_delta 5.0, floors["exact_pct"], 0.01
  assert_in_delta floors["exact_pct"], analyse_case_data["min_total_variation_distance"] * 100, 0.01,
                  "когда перебор возможен, итоговым минимумом обязан быть именно он"
end

# Проверка самой проверки: перебор считаю здесь заново, в тесте, простым
# циклом по всем сочетаниям. Если он разойдётся с тем, что говорит движок,
# виноват движок.
def test_engine_optimum_matches_a_brute_force_written_independently
  queue = RoutingTest.queue_rows
  providers = RoutingTest.providers_payload["providers"]
  external = providers.reject { |p| p["payment_system"] == "spacepayments" }

  eligible = queue.map do |op|
    external.select do |p|
      next false if p["limit_amount_min"] && op["amount"] < p["limit_amount_min"]
      next false if p["limit_amount_max"] && op["amount"] > p["limit_amount_max"]

      banks = p["banks"] || []
      banks.empty? || (p["exclude_banks"] ? !banks.include?(op["bank"]) : banks.include?(op["bank"]))
    end.map { |p| p["payment_system"] }
  end

  headroom = external.to_h do |p|
    [p["payment_system"],
     p["daily_amount_limit"] ? p["daily_amount_limit"] - p["daily_approved_amount"] : Float::INFINITY]
  end
  targets = external.to_h { |p| [p["payment_system"], p["traffic_percentage"].to_f / 100] }

  best = nil
  eligible.first.product(*eligible[1..]) do |combo|
    counts = Hash.new(0)
    spent = Hash.new(0)
    combo.each_with_index { |id, i| counts[id] += 1; spent[id] += queue[i]["amount"] }
    next if headroom.any? { |id, room| spent[id] > room }

    deviation = targets.sum { |id, share| ((counts[id].to_f / queue.size) - share).abs } / 2.0
    best = deviation if best.nil? || deviation < best
  end

  assert_in_delta best * 100, analyse_case_data["floors"]["exact_pct"], 0.01,
                  "движок и независимый перебор обязаны дать одно число"
end

def test_exhaustive_search_is_skipped_when_the_space_is_too_large
  operations = (1..40).map do |i|
    build_operation(id: "big_#{i}", amount: 20_000, bank: "sberbank")
  end
  result = analyse(case_fleet, operations)

  assert_nil result.dig("floors", "exact_pct"),
             "на большой очереди перебор невозможен и обязан честно вернуть пусто"
  refute_nil result["min_total_variation_distance"], "аналитические границы остаются"
end

def test_the_router_lands_on_the_proven_optimum
  report = pipeline[:report]
  actual = report["distribution"].reject { |id, _| id == "spacepayments" }
                                 .sum { |_, row| (row["share_pct"] - row["target_pct"]).abs } / 200.0

  assert_in_delta report.dig("target_achievability", "min_total_variation_distance"), actual, 1e-9,
                  "роутер обязан попадать ровно в доказанный минимум, а не около него"
end

private

def case_fleet
  Routing::Fleet.new(
    RoutingTest.providers_payload["providers"].each_with_index.map do |row, index|
      build_provider(row.merge("payment_system" => row["payment_system"]))
    end
  )
end


  def analyse_case_data = @analyse_case_data ||= pipeline[:report]["target_achievability"]

  def analyse(fleet, operations)
    config = project_config
    Routing::Analytics::Achievability
      .new(fleet: fleet, constraints: Routing::Constraints::Registry.build(config), config: config)
      .analyse(operations)
  end

  def two_providers
    build_fleet([
                  build_provider({ "payment_system" => "narrow", "traffic_percentage" => 50,
                                 "banks" => ["tinkoff"], "exclude_banks" => false}),
                  build_provider({ "payment_system" => "wide", "traffic_percentage" => 50 })
                ])
  end

  def operation(id, amount, bank = "sberbank")
    build_operation(id: id, amount: amount, bank: bank)
  end
end
