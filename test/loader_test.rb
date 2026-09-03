# frozen_string_literal: true

require_relative "test_helper"

# Устойчивость к кривым входным данным.
#
# Правило разделения простое: там, где можно продолжить с разумным
# допущением — продолжаем и пишем замечание; там, где продолжать нечем —
# падаем с внятным сообщением, называющим файл и запись. Молча подставлять
# ноль вместо суммы и делать вид, что всё в порядке, нельзя.
class LoaderTest < Minitest::Test
  def loader(config = nil, issues = nil)
    @issues = issues || Routing::Ingest::Issues.new
    Routing::Ingest::Loader.new(config || project_config, issues: @issues)
  end

  def messages = @issues.to_a.map(&:message)

  def assert_issue(pattern, severity: nil)
    matching = @issues.to_a.select { |issue| issue.message.match?(pattern) }

    refute_empty matching, "ожидалось замечание #{pattern.inspect}, есть только: #{messages.inspect}"
    assert_equal severity, matching.first.severity if severity
    matching.first
  end

  # --- файлы, из которых нельзя продолжить ---------------------------------

  def test_empty_file_is_a_data_error_naming_the_file
    error = assert_raises(Routing::DataError) { loader.load_fleet(fixture("empty.json")) }

    assert_match(/файл пуст/, error.message)
    assert_match(/empty\.json/, error.message)
  end

  def test_broken_json_is_a_data_error_and_not_a_json_parser_error
    error = assert_raises(Routing::DataError) { loader.load_fleet(fixture("broken_json.json")) }

    assert_match(/не разбирается как JSON/, error.message)
    assert_match(/broken_json\.json/, error.message)
  end

  def test_missing_file_is_a_data_error
    error = assert_raises(Routing::DataError) { loader.load_fleet(fixture("не_существует.json")) }

    assert_match(/файл не найден/, error.message)
  end

  def test_provider_without_id_or_name_is_a_data_error_pointing_at_the_row
    error = assert_raises(Routing::DataError) { loader.load_fleet(fixture("providers_no_id.json")) }

    assert_match(/нет ни id, ни name/, error.message)
    assert_match(/providers_no_id\.json\[0\]/, error.message, "в сообщении указан номер записи")
  end

  def test_empty_provider_list_is_a_data_error
    error = assert_raises(Routing::DataError) { loader.load_fleet(fixture("providers_empty.json")) }

    assert_match(/не найдено ни одной записи/, error.message)
  end

  def test_unknown_envelope_shape_is_a_data_error_listing_the_expected_keys
    error = assert_raises(Routing::DataError) { loader.load_fleet(fixture("providers_wrong_shape.json")) }

    assert_match(/не найден массив записей/, error.message)
    assert_match(/providers/, error.message, "сообщение подсказывает, какие ключи ищутся")
  end

  def test_empty_operation_queue_is_a_data_error
    error = assert_raises(Routing::DataError) { loader.load_operations(fixture("operations_empty_list.json")) }

    assert_match(/не найдено ни одной записи заявок/, error.message)
  end

  # --- данные, с которыми можно продолжить ---------------------------------

  def test_provider_with_only_an_id_loads_with_limits_treated_as_absent
    fleet = loader.load_fleet(fixture("providers_minimal.json"))
    provider = fleet.providers.first

    assert_equal %w[bare], fleet.ids
    assert_nil provider.limit_amount_max, "отсутствующий лимит — это отсутствие лимита, а не ноль"
    assert_nil provider.daily_amount_limit
    assert_nil provider.initial_requisites
    assert_predicate provider, :active?, "статус по умолчанию — active"
    assert_in_delta 0.8, provider.conversion_24h, 1e-9, "конверсия взята из ingest.defaults"
    assert_predicate provider.initial_daily_amount, :zero?
  end

  def test_provider_with_only_an_id_is_routable_and_not_blocked_by_missing_fields
    fleet = loader.load_fleet(fixture("providers_minimal.json"))
    provider = fleet.providers.first
    context = context_for(provider: provider, operation: build_operation(amount: 999_999), fleet: fleet)
    violation = Routing::Constraints::Registry.build(project_config)
                                              .filter_map { |c| c.check(context) }.first

    assert_nil violation, "недостающие поля не должны выключать провайдера"
  end

  def test_traffic_percentage_not_summing_to_hundred_is_normalised_with_a_warning
    fleet = loader.load_fleet(fixture("providers_traffic_not_100.json"))

    assert_issue(/сумма traffic_percentage/, severity: :warning)
    assert_in_delta 1.0, fleet.routable.sum { |p| fleet.count_target(p.id) }, 1e-9,
                    "после нормализации доли складываются в 100%"
    assert_in_delta 30.0 / 70, fleet.count_target("alpha"), 1e-9
    assert_in_delta 40.0 / 70, fleet.count_target("beta"), 1e-9
  end

  def test_amount_written_as_a_string_with_spaces_and_comma_is_understood
    operations = loader.load_operations(fixture("operations_messy.json"))

    assert_equal 1000.5, operations.first.amount.as_json
  end

  def test_amount_that_is_not_a_number_falls_back_to_zero_with_a_warning
    operations = loader.load_operations(fixture("operations_messy.json"))
    broken = operations.find { |o| o.id == "op_bad_amount" }

    assert_predicate broken.amount, :zero?
    assert_issue(/не похоже на сумму/, severity: :warning)
  end

  def test_unparseable_timestamp_is_dropped_with_a_warning
    operations = loader.load_operations(fixture("operations_messy.json"))

    assert_issue(/не разобралось как время/, severity: :warning)
    assert(operations.any? { |o| o.created_at.nil? })
  end

  def test_operation_without_id_gets_a_generated_one
    operations = loader.load_operations(fixture("operations_messy.json"))

    assert(operations.all? { |o| !o.id.nil? && !o.id.empty? })
    assert_equal operations.size, operations.map(&:id).size
  end

  def test_duplicate_operation_ids_are_reported_but_do_not_stop_the_run
    operations = loader.load_operations(fixture("operations_messy.json"))

    assert_equal 2, operations.count { |o| o.id == "op_dup" }
    assert_issue(/заявка встречается более одного раза/, severity: :warning)
  end

  def test_unknown_bank_is_normalised_and_left_for_the_bank_filter_to_judge
    operations = loader.load_operations(fixture("operations_messy.json"))
    unknown = operations[1]

    refute_nil unknown.bank_key, "неизвестный банк не выбрасывается: решение принимает правило, а не загрузчик"
    refute_equal "sberbank", unknown.bank_key
  end

  def test_operation_without_a_bank_keeps_a_nil_bank_key
    operations = loader.load_operations(fixture("operations_messy.json"))
    without_bank = operations.find { |o| o.id == "op_no_bank" }

    assert_nil without_bank.bank_key
  end

  def test_unknown_provider_fields_are_kept_and_reported_as_info
    loader.load_fleet(RoutingTest::PROVIDERS_PATH)

    assert_issue(/поля без известного смысла/, severity: :info)
  end

  def test_missing_history_file_does_not_stop_the_run
    assert_empty loader.load_history(nil)
    assert_empty loader.load_history(fixture("не_существует.csv"))
  end

  # --- нормализация имён полей ---------------------------------------------

  def test_field_names_are_matched_regardless_of_case_and_separators
    normalize = Routing::Ingest::FieldMap.method(:normalize_key)

    assert_equal "limit_amount_max", normalize.call("limitAmountMax")
    assert_equal "limit_amount_max", normalize.call("Limit Amount Max")
    assert_equal "limit_amount_max", normalize.call("limit-amount-max")
  end

  def test_provider_fields_are_read_through_synonyms
    provider = build_provider({ "provider_id" => "synonyms", "state" => "active",
                                "traffic_pct" => 100, "max_amount" => 70_000,
                                "min_amount" => 700, "daily_limit" => 900_000,
                                "free_requisites" => 3, "cr" => 0.77 })

    assert_equal "synonyms", provider.id
    assert_equal "active", provider.status
    assert_equal 70_000, provider.limit_amount_max.to_major
    assert_equal 700, provider.limit_amount_min.to_major
    assert_equal 900_000, provider.daily_amount_limit.to_major
    assert_equal 3, provider.initial_requisites
    assert_in_delta 0.77, provider.conversion_24h, 1e-9
  end

  def test_extra_field_aliases_come_from_configuration
    map = Routing::Ingest::FieldMap.new("limit_amount_max" => %w[потолок])
    record = Routing::Ingest::Record.new({ "потолок" => 5000 }, field_map: map,
                                         issues: Routing::Ingest::Issues.new, source: "test")

    assert_equal 5000, record.money("limit_amount_max").to_major
  end

  def test_bank_names_are_normalised_to_one_form
    aliases = { "сбербанк" => "sberbank", "т_банк" => "tinkoff" }

    assert_equal "sberbank", Routing::Bank.normalize("ПАО «Сбербанк»", aliases)
    assert_equal "sberbank", Routing::Bank.normalize("  СБЕРБАНК ", aliases)
    assert_equal "tinkoff", Routing::Bank.normalize("Т-Банк", aliases)
    assert_equal "raiffeisen", Routing::Bank.normalize("raiffeisen")
    assert_nil Routing::Bank.normalize(nil)
  end

  # --- боевые данные --------------------------------------------------------

  def test_real_providers_file_loads_with_no_errors
    fleet = loader.load_fleet(RoutingTest::PROVIDERS_PATH)

    assert_equal %w[vipay payflow quickpay spacepayments], fleet.ids
    refute_predicate @issues, :any_errors?
    assert_equal %w[vipay payflow quickpay], fleet.routable.map(&:id)
    assert_equal %w[spacepayments], fleet.self_providers.map(&:id)
  end

  def test_real_queue_loads_with_no_errors
    operations = loader.load_operations(RoutingTest::QUEUE_PATH)

    assert_equal 10, operations.size
    assert_equal queue_rows.map { |row| row["operation_id"] }, operations.map(&:id)
    refute_predicate @issues, :any_errors?
  end

  def test_real_history_loads_and_calibrates
    history = loader.load_history(RoutingTest::HISTORY_PATH)
    calibration = Routing::Calibration.new(history, project_config)

    assert_equal 100, history.size
    assert_equal %w[payflow quickpay vipay], calibration.providers
    calibration.providers.each do |id|
      rate = calibration.success_rate_for(id)

      assert_operator rate, :>=, 0.0
      assert_operator rate, :<=, 1.0
      assert_operator calibration.conservative_rate_for(id), :<=, rate,
                      "нижняя граница не может быть выше наблюдённой частоты"
    end
    assert_in_delta 1.0, calibration.observed_shares.values.sum, 1e-9
  end

  def test_envelope_fields_survive_loading_and_reach_the_report
    instance = loader
    instance.load_fleet(RoutingTest::PROVIDERS_PATH)

    assert_equal "2026-07-30T09:00:00+03:00", instance.meta["snapshot_at"]
    assert_equal "alpha_market", instance.meta["merchant"]
    refute_includes instance.meta.keys, "providers", "сама коллекция в метаданные не попадает"
  end

  # --- конфигурация ---------------------------------------------------------

  def test_configuration_file_is_optional
    config = Routing::Config.load(nil)

    assert_equal "balanced", config.fetch("profile")
    refute_empty config.enabled_constraint_ids
    refute_empty config.enabled_strategy_ids
  end

  def test_missing_configuration_file_is_a_configuration_error
    error = assert_raises(Routing::ConfigError) { Routing::Config.load(fixture("нет_такого.yml")) }

    assert_match(/не найден/, error.message)
  end

  def test_unknown_profile_is_a_configuration_error
    error = assert_raises(Routing::ConfigError) { project_config.with_profile("несуществующий") }

    assert_match(/несуществующий/, error.message)
  end

  def test_every_declared_profile_builds_a_working_pipeline
    config = project_config

    refute_empty config.profiles
    config.profiles.each do |name|
      profiled = config.with_profile(name)

      assert_equal name, profiled.fetch("profile")
      refute_empty Routing::Strategies::Registry.build(profiled),
                   "профиль #{name} не должен выключать все цели разом"
      refute_empty Routing::Constraints::Registry.build(profiled)
    end
  end

  def test_deep_merge_keeps_untouched_branches
    merged = project_config.merge("strategies" => { "conversion" => { "weight" => 9.9 } })

    assert_in_delta 9.9, merged.fetch("strategies", "conversion", "weight")
    assert_equal project_config.fetch("strategies", "conversion", "estimator"),
                 merged.fetch("strategies", "conversion", "estimator"),
                 "перекрытие одного параметра не стирает соседние"
  end

  # --- найденные расхождения ------------------------------------------------

  def test_default_configuration_declares_the_simulation_keys_the_simulator_reads

    simulation = Routing::Config::DEFAULTS["simulation"]

    %w[cascade_on expired_share_of_failures history_weight].each do |key|
      assert_includes simulation.keys, key, "симулятор читает #{key}, а DEFAULTS его не объявляет"
    end
    %w[spread rejected_sec expired_sec base_sec].each do |key|
      assert_includes simulation["latency"].keys, key
    end
  end

  def test_daily_turnover_max_is_read_as_a_separate_field_from_the_daily_limit

    provider = build_provider({ "payment_system" => "acme", "status" => "active",
                                "traffic_percentage" => 100, "daily_turnover_max" => 1_000_000 })

    assert_equal 1_000_000, provider.daily_turnover_max.to_major
    assert_nil provider.daily_amount_limit,
               "технического дневного лимита в данных не было — он не должен появляться сам"
  end
end
