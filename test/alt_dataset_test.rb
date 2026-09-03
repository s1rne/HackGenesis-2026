# frozen_string_literal: true

require_relative "test_helper"

# Второй набор данных.
#
# Здесь проверяется не качество маршрутизации, а независимость конвейера от
# конкретного файла с данными. Набор в test/fixtures/alt_dataset собран так,
# чтобы отличаться от кейсового по всему, по чему он может отличаться:
#
#   * другой шлюз, другие партнёры, другая валюта и другие банки;
#   * другая обёртка файла провайдеров (ключ payment_systems, а не providers)
#     и другая метка снимка (generated_at, а не snapshot_at);
#   * другие имена полей: provider_id, trafficShare, max_amount, cr,
#     terminals, allowed_banks, banks_exclude, ccy — и то же самое в заявках:
#     id, sum, bank_name, created, beneficiary_bank, accepted_at;
#   * суммы и числом, и строкой «2 850 000», и строкой «25000,50»;
#   * один провайдер выключен, один работает по ЧЁРНОМУ списку банков,
#     один — собственный шлюз последней надежды;
#   * целевые доли в сумме дают 105, а не 100;
#   * часть заявок без времени создания.
#
# Ни одной строки кода под этот набор не написано: отличаются только данные
# и конфигурация рядом с ними.
class AltDatasetTest < Minitest::Test
  DIR = File.join(RoutingTest::FIXTURES_DIR, "alt_dataset")
  CONFIG = File.join(DIR, "config.yml")
  PROVIDERS = File.join(DIR, "providers.json")
  QUEUE = File.join(DIR, "operations_queue.json")

  # Провайдеры набора, вынесенные в константы: тест должен ломаться от правки
  # данных осмысленно, а не десятком одинаковых строковых литералов.
  SELF_PROVIDER = "internal_settlement"
  DISABLED_PROVIDER = "nordwind_pay"
  BLACKLIST_PROVIDER = "orbita_gate"
  # Банки, которых нет ни в одном белом списке и которые вдобавок стоят
  # в чёрном списке единственного универсального провайдера.
  UNROUTABLE_BANKS = %w[monobank privatbank].freeze

  # Аргументы одного прогона. История и накладка отключены намеренно: и та,
  # и другая относятся к кейсовому набору, а этот шлюз своей истории не имеет.
  ARGS = ["--config", CONFIG, "--providers", PROVIDERS, "--queue", QUEUE,
          "--history", "", "--overlays", ""].freeze

  def self.run_alt
    result = RoutingTest.run_pipeline(ARGS)
    RoutingTest.register_temp_dir(result[:dir])
    result
  end

  # Один прогон на весь класс: он занимает доли секунды, но повторять его
  # в каждой проверке незачем. Повторный прогон делает только тест на
  # воспроизводимость — ему он нужен по существу.
  def self.pipeline = @pipeline ||= run_alt

  def setup
    @run = self.class.pipeline
    @decisions = @run[:decisions]
    @report = @run[:report]
  end

  def providers_payload
    @providers_payload ||= JSON.parse(File.read(PROVIDERS))["payment_systems"]
  end

  def queue_payload = @queue_payload ||= JSON.parse(File.read(QUEUE))

  def selected_for(operation_id)
    decision = @decisions.find { |d| d["operation_id"] == operation_id }

    refute_nil decision, "в выгрузке нет заявки #{operation_id}"
    decision["selected_provider"]
  end

  def bank_of(decision) = decision["bank"].to_s.downcase

  # --- 1. прогон вообще состоялся ------------------------------------------

  def test_alternative_dataset_runs_through_the_same_pipeline_without_errors
    assert_predicate @run[:status], :success?,
                     "конвейер завершился с кодом #{@run[:status].exitstatus}:\n#{@run[:output]}"
    assert_equal queue_payload.size, @decisions.size, "в выгрузке не все заявки набора"
  end

  def test_every_operation_got_a_provider
    without = @decisions.reject { |d| d["selected_provider"].to_s != "" }

    assert_empty without.map { |d| d["operation_id"] }, "заявки остались без провайдера"
  end

  def test_operation_ids_are_read_from_the_alternative_field_names
    expected = queue_payload.map { |row| row["id"] || row["operation_id"] }

    assert_equal expected.sort, @decisions.map { |d| d["operation_id"] }.sort
  end

  # Суммы в наборе записаны тремя способами: числом, строкой с пробелами
  # и строкой с запятой в роли десятичного разделителя. Если хоть один
  # разобрался неверно, заявка поедет не в тот диапазон.
  def test_amounts_written_as_strings_are_parsed
    assert_in_delta 2_850_000.0, @decisions.find { |d| d["operation_id"] == "pay-2005" }["amount"], 0.001
    assert_in_delta 25_000.5, @decisions.find { |d| d["operation_id"] == "pay-2025" }["amount"], 0.001
  end

  # --- 2. выключенный провайдер --------------------------------------------

  def test_the_dataset_really_contains_a_disabled_provider
    row = providers_payload.find { |p| p["provider_id"] == DISABLED_PROVIDER }

    refute_nil row, "в наборе нет провайдера #{DISABLED_PROVIDER}"
    refute_equal "active", row["state"], "провайдер #{DISABLED_PROVIDER} должен быть не в рабочем статусе"
  end

  def test_disabled_provider_is_never_selected
    got = @decisions.select { |d| d["selected_provider"] == DISABLED_PROVIDER }

    assert_empty got.map { |d| d["operation_id"] },
                 "провайдер со статусом не active не должен получать заявки"
  end

  def test_disabled_provider_is_skipped_with_the_status_reason
    decision = @decisions.first
    attempt = decision["attempts"].find { |a| a["provider"] == DISABLED_PROVIDER }

    refute_nil attempt, "в attempts нет записи о #{DISABLED_PROVIDER}"
    assert_equal "provider_inactive", attempt["reason"]
  end

  # --- 3. заявки, для которых нет ни одного внешнего маршрута ---------------

  def test_operations_with_a_bank_nobody_serves_go_to_the_self_provider
    operations = @decisions.select { |d| UNROUTABLE_BANKS.include?(bank_of(d)) }

    refute_empty operations, "в наборе должны быть заявки с банком вне всех белых списков"
    operations.each do |decision|
      assert_equal SELF_PROVIDER, decision["selected_provider"],
                   "#{decision['operation_id']} (#{decision['bank']}) должна была уйти на собственный шлюз"
      assert_equal "fallback_self_provider", decision["selection"]["reason"]
    end
  end

  def test_self_provider_takes_only_the_operations_nobody_else_can_take
    taken = @decisions.select { |d| d["selected_provider"] == SELF_PROVIDER }

    assert_equal UNROUTABLE_BANKS.sort, taken.map { |d| bank_of(d) }.sort,
                 "на собственный шлюз ушло не то, что должно было"
  end

  # --- 4. чёрный список банков ---------------------------------------------

  def blacklist
    row = providers_payload.find { |p| p["provider_id"] == BLACKLIST_PROVIDER }

    refute_nil row, "в наборе нет провайдера #{BLACKLIST_PROVIDER}"
    assert_equal true, row["banks_exclude"], "у #{BLACKLIST_PROVIDER} banks должен читаться как чёрный список"
    row["allowed_banks"]
  end

  def test_provider_with_exclude_banks_flag_never_gets_a_blacklisted_bank
    denied = blacklist
    got = @decisions.select { |d| d["selected_provider"] == BLACKLIST_PROVIDER }

    refute_empty got, "#{BLACKLIST_PROVIDER} не получил ни одной заявки — проверка стала бессмысленной"
    got.each do |decision|
      refute_includes denied, bank_of(decision),
                      "#{decision['operation_id']}: #{decision['bank']} в чёрном списке #{BLACKLIST_PROVIDER}"
    end
  end

  # Обратная сторона того же флага: банк из чёрного списка, у которого есть
  # другой маршрут, должен уйти этим другим маршрутом, а не на fallback.
  def test_blacklisted_bank_with_another_route_is_routed_there
    freedom = @decisions.select { |d| bank_of(d).start_with?("freedom") }

    refute_empty freedom, "в наборе должны быть заявки в банк из чёрного списка"
    freedom.each do |decision|
      refute_equal BLACKLIST_PROVIDER, decision["selected_provider"]
      refute_equal SELF_PROVIDER, decision["selected_provider"],
                   "#{decision['operation_id']}: маршрут был, уходить на собственный шлюз незачем"
    end
  end

  # --- 5. замечания к данным -----------------------------------------------

  def data_quality_messages
    quality = @report["data_quality"]

    refute_nil quality, "в отчёте нет раздела data_quality"
    quality["items"].map { |item| item["message"] }
  end

  def test_report_notes_that_traffic_targets_were_normalized
    total = providers_payload.sum { |p| p["self_provider"] ? 0 : p["trafficShare"].to_f }

    refute_in_delta 100.0, total, 0.5, "набор задуман с суммой долей, не равной 100"
    assert(data_quality_messages.any? { |m| m.match?(/traffic_percentage.+нормализован/) },
           "ожидалось замечание о нормализации целевых долей, есть: #{data_quality_messages.inspect}")
  end

  def test_report_notes_the_field_it_did_not_recognize
    assert(data_quality_messages.any? { |m| m.include?("sla_tier") },
           "поле без известного смысла должно попасть в замечания: #{data_quality_messages.inspect}")
  end

  # --- 6. состав отчёта ------------------------------------------------------

  REQUIRED_REPORT_SECTIONS = %w[period total_operations distribution skip_reasons
                                projected_daily_utilization recommendations].freeze

  def test_report_carries_all_required_sections
    REQUIRED_REPORT_SECTIONS.each do |key|
      assert @report.key?(key), "в отчёте нет обязательного раздела #{key}"
    end
    assert_equal @decisions.size, @report["total_operations"]
  end

  def test_report_distribution_covers_every_provider_of_the_dataset
    expected = providers_payload.map { |p| p["provider_id"] }

    assert_equal expected.sort, @report["distribution"].keys.sort
  end

  # --- 7. воспроизводимость --------------------------------------------------

  def test_two_runs_produce_byte_identical_output
    second = self.class.run_alt

    assert_predicate second[:status], :success?
    assert_equal @decisions, second[:decisions], "два прогона на одном наборе дали разные решения"
    assert_equal @report.reject { |k, _| k == "source" },
                 second[:report].reject { |k, _| k == "source" },
                 "два прогона на одном наборе дали разные отчёты"
  end
end
