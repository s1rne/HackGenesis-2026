# frozen_string_literal: true

require_relative "test_helper"

# Жёсткие ограничения — по одному на класс.
#
# Каждое правило проверяется дважды: что оно срабатывает там, где обязано,
# и что оно молчит там, где повода нет. Второе не менее важно: правило,
# которое отсекает лишнего, выключает провайдера без причины, и в отчёте
# это выглядит как «так и было задумано».
class ConstraintsTest < Minitest::Test
  C = Routing::Constraints

  ACTIVE = {
    "payment_system" => "acme",
    "status" => "active",
    "traffic_percentage" => 50,
    "limit_amount_min" => 1000,
    "limit_amount_max" => 100_000,
    "available_requisites" => 5,
    "provider_margin_pct" => 1.0,
    "merchant_margin_pct" => 1.5
  }.freeze

  def check(constraint, provider_attrs, operation_attrs = {}, at: 0.0, state: nil)
    provider = provider_attrs.is_a?(Routing::Provider) ? provider_attrs : build_provider(ACTIVE.merge(provider_attrs))
    fleet = build_fleet([provider])
    state&.call(fleet[provider.id])
    operation = build_operation(**operation_attrs)
    constraint.check(context_for(provider: provider, operation: operation, fleet: fleet, at: at))
  end

  def assert_violation(code, violation, message = nil)
    refute_nil violation, message || "ожидалось нарушение #{code}, правило пропустило провайдера"
    assert_equal code, violation.reason, message
    refute_nil violation.details, "у нарушения #{code} нет пояснения для человека"
    assert Routing::Reasons.known?(violation.reason), "код #{violation.reason} не описан в каталоге причин"
    violation
  end

  # --- 1. статус провайдера -------------------------------------------------

  def test_provider_status_blocks_inactive_provider
    violation = check(C::ProviderStatus.new, { "status" => "disabled" })

    assert_violation "provider_inactive", violation
    assert_match(/disabled/, violation.details)
  end

  def test_provider_status_allows_active_provider
    assert_nil check(C::ProviderStatus.new, { "status" => "active" })
    assert_nil check(C::ProviderStatus.new, { "status" => "ACTIVE" }), "статус читается без учёта регистра"
  end

  # --- 2. нулевая целевая доля ---------------------------------------------

  def test_traffic_share_blocks_provider_without_target_share
    violation = check(C::TrafficShare.new, { "traffic_percentage" => 0 })

    assert_violation "zero_traffic_share", violation
  end

  def test_traffic_share_allows_provider_with_target_share
    assert_nil check(C::TrafficShare.new, { "traffic_percentage" => 25 })
  end

  def test_traffic_share_never_blocks_the_fallback_provider
    fallback = build_provider(ACTIVE.merge("payment_system" => "spacepayments", "traffic_percentage" => 0),
                              self_provider_ids: ["spacepayments"])

    assert_predicate fallback, :self_provider?
    assert_nil check(C::TrafficShare.new, fallback),
               "self-провайдер с нулевой долей — это fallback, а не выключенный гейт"
  end

  # --- 3. валюта ------------------------------------------------------------

  def test_currency_blocks_unsupported_currency
    violation = check(C::Currency.new, { "currency" => %w[RUB KZT] }, { currency: "USD" })

    assert_violation "currency_not_supported", violation
    assert_match(/USD/, violation.details)
  end

  def test_currency_allows_supported_currency
    assert_nil check(C::Currency.new, { "currency" => %w[RUB KZT] }, { currency: "RUB" })
    assert_nil check(C::Currency.new, { "currency" => "rub" }, { currency: "RUB" })
  end

  def test_currency_is_not_applicable_when_provider_lists_no_currencies
    assert_nil check(C::Currency.new, {}, { currency: "USD" }),
               "отсутствие списка валют — это отсутствие ограничения, а не запрет"
  end

  # --- 4. диапазон суммы ----------------------------------------------------

  def test_amount_range_blocks_amount_below_minimum
    violation = check(C::AmountRange.new, { "limit_amount_min" => 1000 }, { amount: 800 })

    assert_violation "amount_below_minimum", violation
    assert_match(/limit_amount_min/, violation.details)
  end

  def test_amount_range_blocks_amount_above_maximum
    violation = check(C::AmountRange.new, { "limit_amount_max" => 100_000 }, { amount: 150_000 })

    assert_violation "amount_exceeds_limit", violation
    assert_match(/limit_amount_max/, violation.details)
  end

  def test_amount_range_allows_amount_inside_the_range_including_borders
    assert_nil check(C::AmountRange.new, {}, { amount: 50_000 })
    assert_nil check(C::AmountRange.new, {}, { amount: 1000 }), "нижняя граница включительна"
    assert_nil check(C::AmountRange.new, {}, { amount: 100_000 }), "верхняя граница включительна"
  end

  def test_amount_range_is_not_applicable_without_limits
    provider = build_provider({ "payment_system" => "open", "status" => "active", "traffic_percentage" => 10 })

    assert_nil check(C::AmountRange.new, provider, { amount: 10_000_000 })
  end

  # --- 5. дневной лимит по обороту -----------------------------------------

  def test_daily_amount_limit_blocks_operation_that_does_not_fit
    violation = check(C::DailyAmountLimit.new,
                      { "daily_amount_limit" => 5_000_000, "daily_approved_amount" => 3_200_000 },
                      { amount: 2_000_000 })

    assert_violation "daily_limit_exceeded", violation
    assert_match(/daily_amount_limit/, violation.details)
  end

  def test_daily_amount_limit_allows_operation_that_fits_exactly
    assert_nil check(C::DailyAmountLimit.new,
                     { "daily_amount_limit" => 5_000_000, "daily_approved_amount" => 3_200_000 },
                     { amount: 1_800_000 }),
               "заявка ровно до лимита проходит: проверка на «больше», а не «больше либо равно»"
  end

  def test_daily_amount_limit_does_not_lie_on_the_float_boundary
    # На Float 1000.08 + 2000.16 > 3000.24 — правило отсекло бы провайдера
    # без причины. На целых копейках сумма ровно равна лимиту.
    assert_nil check(C::DailyAmountLimit.new,
                     { "daily_amount_limit" => 3000.24, "daily_approved_amount" => 1000.08 },
                     { amount: 2000.16 })
    assert_operator(1000.08 + 2000.16, :>, 3000.24)
  end

  def test_daily_amount_limit_is_not_applicable_without_limit
    assert_nil check(C::DailyAmountLimit.new, { "daily_approved_amount" => 10_000_000 }, { amount: 5_000_000 })
  end

  # --- 6. верхнее обязательство по обороту ---------------------------------

  # Поле задаётся синонимом turnover_commitment_max: канонический
  # `daily_turnover_max` во входных данных подхватывается ещё и картой полей
  # дневного лимита. Отдельный тест на это столкновение — в loader_test.rb.
  def test_daily_turnover_max_blocks_operation_over_the_commitment
    violation = check(C::DailyTurnoverMax.new,
                      { "turnover_commitment_max" => 1_000_000, "daily_approved_amount" => 900_000 },
                      { amount: 200_000 })

    assert_violation "daily_turnover_max_exceeded", violation
    assert_match(/daily_turnover_max/, violation.details)
  end

  def test_daily_turnover_max_allows_operation_within_the_commitment
    assert_nil check(C::DailyTurnoverMax.new,
                     { "turnover_commitment_max" => 1_000_000, "daily_approved_amount" => 900_000 },
                     { amount: 100_000 })
  end

  def test_daily_turnover_max_is_not_applicable_without_commitment
    assert_nil check(C::DailyTurnoverMax.new, { "daily_approved_amount" => 900_000 }, { amount: 5_000_000 })
  end

  # --- 7. заявки в работе ---------------------------------------------------

  def test_in_progress_limits_block_when_count_slots_are_taken
    violation = check(C::InProgressLimits.new,
                      { "in_progress_count_limit" => 10, "in_progress_count" => 10 })

    assert_violation "in_progress_count_limit", violation
  end

  def test_in_progress_limits_block_when_amount_in_flight_is_too_large
    violation = check(C::InProgressLimits.new,
                      { "in_progress_amount_limit" => 500_000, "in_progress_amount" => 480_000 },
                      { amount: 50_000 })

    assert_violation "in_progress_amount_limit", violation
  end

  def test_in_progress_limits_allow_when_there_is_room
    assert_nil check(C::InProgressLimits.new,
                     { "in_progress_count_limit" => 10, "in_progress_count" => 4,
                       "in_progress_amount_limit" => 1_000_000, "in_progress_amount" => 380_000 },
                     { amount: 50_000 })
  end

  def test_in_progress_limits_allow_the_last_free_slot
    assert_nil check(C::InProgressLimits.new,
                     { "in_progress_count_limit" => 5, "in_progress_count" => 4 }),
               "последний свободный слот всё ещё свободен"
  end

  def test_in_progress_limits_are_not_applicable_without_limits
    assert_nil check(C::InProgressLimits.new, { "in_progress_count" => 100, "in_progress_amount" => 10_000_000 })
  end

  # --- 8. банковский фильтр -------------------------------------------------
  #
  # Поле exclude_banks прочитывается двумя способами. В данных кейса это
  # булев флаг: false — banks белый список, true — чёрный. В тексте ТЗ то же
  # поле описано как отдельный список банков-исключений. Проверяем оба.

  def test_bank_filter_treats_banks_as_whitelist_when_flag_is_false
    attrs = { "banks" => %w[sberbank tinkoff vtb], "exclude_banks" => false }

    assert_nil check(C::BankFilter.new, attrs, { bank: "sberbank" })
    violation = check(C::BankFilter.new, attrs, { bank: "alfa" })

    assert_violation "bank_not_in_list", violation
    assert_match(/alfa/, violation.details)
  end

  def test_bank_filter_treats_banks_as_blacklist_when_flag_is_true
    attrs = { "banks" => %w[sberbank tinkoff], "exclude_banks" => true }
    provider = build_provider(ACTIVE.merge(attrs))

    assert provider.banks_are_blacklist, "флаг exclude_banks=true переводит banks в чёрный список"
    violation = check(C::BankFilter.new, provider, { bank: "sberbank" })

    assert_violation "bank_excluded", violation
    assert_nil check(C::BankFilter.new, provider, { bank: "alfa" }),
               "при чёрном списке всё, чего в нём нет, разрешено"
  end

  def test_bank_filter_reads_exclude_banks_written_as_a_list
    # Прочтение из текста ТЗ: exclude_banks — самостоятельный список.
    attrs = { "banks" => [], "exclude_banks" => %w[alfa raiffeisen] }
    provider = build_provider(ACTIVE.merge(attrs))

    refute provider.banks_are_blacklist, "список в exclude_banks — это исключения, а не флаг режима"
    assert_equal %w[alfa raiffeisen], provider.exclude_banks

    violation = check(C::BankFilter.new, provider, { bank: "alfa" })

    assert_violation "bank_excluded", violation
    assert_nil check(C::BankFilter.new, provider, { bank: "sberbank" })
  end

  def test_bank_filter_combines_whitelist_and_explicit_exclusions
    provider = build_provider(ACTIVE.merge("banks" => %w[sberbank alfa tinkoff],
                                           "exclude_banks" => %w[tinkoff]))

    assert_nil check(C::BankFilter.new, provider, { bank: "sberbank" })
    assert_violation "bank_excluded", check(C::BankFilter.new, provider, { bank: "tinkoff" }),
                     "явное исключение сильнее белого списка"
    assert_violation "bank_not_in_list", check(C::BankFilter.new, provider, { bank: "vtb" })
  end

  def test_bank_filter_accepts_any_bank_when_no_lists_are_configured
    attrs = { "banks" => [], "exclude_banks" => false }

    assert_nil check(C::BankFilter.new, attrs, { bank: "gazprombank" }),
               "пустой banks без исключений — универсальный провайдер, а не «ни одного банка»"
    assert_nil check(C::BankFilter.new, attrs, { bank: nil })
  end

  def test_bank_filter_normalizes_bank_names_before_comparing
    aliases = { "сбербанк" => "sberbank" }
    provider = build_provider(ACTIVE.merge("banks" => ["Сбербанк"], "exclude_banks" => false),
                              bank_aliases: aliases)
    fleet = build_fleet([provider])
    operation = build_operation(bank: "ПАО «Сбербанк»", bank_aliases: aliases)

    assert_equal "sberbank", operation.bank_key
    assert_nil C::BankFilter.new.check(context_for(provider: provider, operation: operation, fleet: fleet))
  end

  def test_bank_filter_passes_unknown_bank_when_policy_allows
    attrs = { "banks" => %w[sberbank], "exclude_banks" => false }

    assert_nil check(C::BankFilter.new("unknown_bank_policy" => "allow"), attrs, { bank: nil })
  end

  def test_bank_filter_blocks_unknown_bank_when_policy_denies
    attrs = { "banks" => %w[sberbank], "exclude_banks" => false }
    violation = check(C::BankFilter.new("unknown_bank_policy" => "deny"), attrs, { bank: nil })

    assert_violation "bank_unknown", violation
  end

  def test_bank_filter_ignores_unknown_bank_policy_without_whitelist
    attrs = { "banks" => [], "exclude_banks" => %w[alfa] }

    assert_nil check(C::BankFilter.new("unknown_bank_policy" => "deny"), attrs, { bank: nil }),
               "без белого списка неизвестный банк ничему не противоречит"
  end

  # --- 9. маржа -------------------------------------------------------------

  def test_margin_blocks_provider_that_eats_the_whole_merchant_margin
    violation = check(C::Margin.new, { "provider_margin_pct" => 2.0, "merchant_margin_pct" => 1.5 })

    assert_violation "negative_margin", violation
    assert_match(/allow_negative_agreement/, violation.details)
  end

  def test_margin_allows_provider_within_merchant_margin
    assert_nil check(C::Margin.new, { "provider_margin_pct" => 1.2, "merchant_margin_pct" => 1.5 })
    assert_nil check(C::Margin.new, { "provider_margin_pct" => 1.5, "merchant_margin_pct" => 1.5 }),
               "равная маржа не убыточна"
  end

  def test_margin_allows_negative_agreement_when_it_is_explicit
    assert_nil check(C::Margin.new, { "provider_margin_pct" => 2.0, "merchant_margin_pct" => 1.5,
                                      "allow_negative_agreement" => true })
  end

  def test_margin_is_not_applicable_when_merchant_margin_is_unknown
    provider = build_provider({ "payment_system" => "acme", "status" => "active",
                               "traffic_percentage" => 10, "provider_margin_pct" => 9.9 })

    assert_nil check(C::Margin.new, provider),
               "недостающий столбец не должен выключать всех провайдеров разом"
  end

  # --- 10. реквизиты --------------------------------------------------------

  def test_requisites_block_provider_without_free_requisites
    violation = check(C::Requisites.new, { "available_requisites" => 0 })

    assert_violation "no_available_requisites", violation
  end

  def test_requisites_allow_provider_with_at_least_one_free_requisite
    assert_nil check(C::Requisites.new, { "available_requisites" => 1 })
  end

  def test_requisites_are_not_applicable_when_the_field_is_absent
    provider = build_provider({ "payment_system" => "acme", "status" => "active", "traffic_percentage" => 10 })

    assert_nil check(C::Requisites.new, provider)
  end

  # --- 11. интенсивность ----------------------------------------------------

  def test_rate_limit_blocks_when_the_window_is_full
    violation = check(C::RateLimit.new("window_sec" => 60),
                      { "requests_per_minute_limit" => 2 },
                      {}, at: 1000.0,
                      state: ->(s) { s.record_request(998.0); s.record_request(999.0) })

    assert_violation "rate_limit_exceeded", violation
    assert_match(/2/, violation.details)
  end

  def test_rate_limit_allows_while_the_window_has_room
    assert_nil check(C::RateLimit.new("window_sec" => 60),
                     { "requests_per_minute_limit" => 3 },
                     {}, at: 1000.0,
                     state: ->(s) { s.record_request(998.0); s.record_request(999.0) })
  end

  def test_rate_limit_forgets_requests_outside_the_window
    assert_nil check(C::RateLimit.new("window_sec" => 60),
                     { "requests_per_minute_limit" => 1 },
                     {}, at: 1000.0,
                     state: ->(s) { s.record_request(900.0) }),
               "окно скользящее: заявка минутной давности лимит уже не занимает"
  end

  def test_rate_limit_is_not_applicable_without_limit
    assert_nil check(C::RateLimit.new, {}, {}, at: 1000.0,
                     state: ->(s) { 50.times { |i| s.record_request(1000.0 - i) } })
  end

  # --- реестр ---------------------------------------------------------------

  def test_registry_knows_every_hard_constraint_of_the_case
    expected = %w[
      amount_range bank_filter currency daily_amount_limit daily_turnover_max
      in_progress_limits margin provider_status rate_limit requisites traffic_share
    ]

    assert_equal expected, (expected & C::Registry.known_ids).sort
    assert_equal 11, expected.size
  end

  def test_registry_builds_constraints_in_configuration_order
    config = project_config
    built = C::Registry.build(config)

    assert_equal config.enabled_constraint_ids, built.map(&:id),
                 "порядок проверки задаётся конфигурацией: он определяет, какая причина попадёт в отчёт"
  end

  def test_registry_skips_disabled_constraints
    config = config_with({ "hard_constraints" => { "rate_limit" => { "enabled" => false } } })

    refute_includes C::Registry.build(config).map(&:id), "rate_limit"
  end

  def test_registry_refuses_unknown_constraint_names
    config = config_with({ "hard_constraints" => { "phase_of_the_moon" => { "enabled" => true } } })
    error = assert_raises(Routing::ConfigError) { C::Registry.build(config) }

    assert_match(/phase_of_the_moon/, error.message)
  end

  def test_base_constraint_demands_an_implementation
    assert_raises(NotImplementedError) { C::Base.new.check(nil) }
  end
end
