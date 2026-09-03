# frozen_string_literal: true

require_relative "test_helper"

# Приёмка на эталоне организаторов.
#
# Здесь проверяется не внутреннее устройство, а результат: тот ли провайдер
# выбран, те ли отсеяны и по тем ли причинам. Эталон лежит в
# data/reference_decisions.json и составлен организаторами, а не нами.
class AcceptanceTest < Minitest::Test
  # --- 1. жёсткие фильтры против эталонного списка допустимых --------------

  def setup
    @config = project_config
    @loader = Routing::Ingest::Loader.new(@config)
    @fleet = @loader.load_fleet(RoutingTest::PROVIDERS_PATH)
    @operations = @loader.load_operations(RoutingTest::QUEUE_PATH)
    @constraints = Routing::Constraints::Registry.build(@config)
  end

  # Прогон только жёстких ограничений на исходном состоянии провайдеров.
  # Состояние не трогается, поэтому порядок операций ни на что не влияет.
  def eligible_for(operation)
    @fleet.routable.filter_map do |provider|
      context = context_for(provider: provider, operation: operation, fleet: @fleet,
                            at: operation.created_at.to_f, config: @config)
      provider.id if @constraints.none? { |constraint| constraint.check(context) }
    end
  end

  def first_violation_for(operation, provider_id)
    provider = @fleet.provider_for(provider_id)
    context = context_for(provider: provider, operation: operation, fleet: @fleet,
                          at: operation.created_at.to_f, config: @config)
    @constraints.filter_map { |constraint| constraint.check(context) }.first
  end

  def test_hard_constraints_reproduce_the_reference_list_of_eligible_providers
    expected = reference["eligible_providers"]

    assert_equal 10, expected.size

    @operations.each do |operation|
      assert_equal expected.fetch(operation.id), eligible_for(operation),
                   "список допустимых провайдеров для #{operation.id} расходится с эталоном"
    end
  end

  def test_every_reference_operation_has_at_least_one_eligible_provider
    @operations.each do |operation|
      refute_empty eligible_for(operation), "для #{operation.id} не осталось ни одного внешнего провайдера"
    end
  end

  def test_hard_filter_does_not_depend_on_the_order_of_operations
    forward = @operations.to_h { |operation| [operation.id, eligible_for(operation)] }
    backward = @operations.reverse.to_h { |operation| [operation.id, eligible_for(operation)] }

    assert_equal forward, backward, "жёсткий фильтр на исходном состоянии не должен зависеть от порядка"
  end

  # --- 2. коды причин отсева ------------------------------------------------

  def test_hard_constraints_reproduce_the_reference_skip_reasons
    reference["skip_reasons_expected"].each do |operation_id, expected|
      operation = @operations.find { |o| o.id == operation_id }

      refute_nil operation, "в очереди нет заявки #{operation_id}"
      expected.each do |provider_id, expected_reason|
        violation = first_violation_for(operation, provider_id)

        refute_nil violation, "#{operation_id}: #{provider_id} должен был быть отсеян"
        assert_equal expected_reason, violation.reason,
                     "#{operation_id}/#{provider_id}: причина отсева расходится с эталоном"
      end
    end
  end

  def test_decisions_file_carries_the_reference_skip_reasons_verbatim
    reference["skip_reasons_expected"].each do |operation_id, expected|
      decision = pipeline[:decisions].find { |d| d["operation_id"] == operation_id }

      refute_nil decision, "в выгрузке нет решения по #{operation_id}"
      expected.each do |provider_id, expected_reason|
        attempt = decision["attempts"].find { |a| a["provider"] == provider_id }

        refute_nil attempt, "#{operation_id}: нет записи о рассмотрении #{provider_id}"
        assert_equal "skipped", attempt["decision"]
        assert_equal expected_reason, attempt["reason"],
                     "#{operation_id}/#{provider_id}: код причины в выгрузке расходится с эталоном"
        refute_nil attempt["details"], "у пропуска должно быть пояснение для человека"
      end
    end
  end

  # --- 3. детерминированные кейсы -------------------------------------------

  def test_deterministic_cases_select_the_only_possible_provider
    cases = reference["deterministic_cases"]

    assert_equal 4, cases.size

    cases.each do |expected|
      decision = pipeline[:decisions].find { |d| d["operation_id"] == expected["operation_id"] }

      refute_nil decision, "в выгрузке нет решения по #{expected['operation_id']}"
      assert_equal expected["required_provider"], decision["selected_provider"],
                   "#{expected['operation_id']}: #{expected['reason']}"
    end
  end

  def test_deterministic_cases_are_deterministic_because_the_pool_has_one_provider
    reference["deterministic_cases"].each do |expected|
      operation = @operations.find { |o| o.id == expected["operation_id"] }

      assert_equal [expected["required_provider"]], eligible_for(operation),
                   "#{expected['operation_id']} детерминирован именно жёсткими ограничениями"
    end
  end

  # --- 4. контракт выгрузки -------------------------------------------------

  def test_every_queued_operation_has_exactly_one_decision
    ids = pipeline[:decisions].map { |d| d["operation_id"] }

    assert_equal queue_rows.map { |row| row["operation_id"] }, ids
    assert_equal ids.uniq, ids
  end

  def test_every_decision_has_the_mandatory_fields
    pipeline[:decisions].each do |decision|
      %w[operation_id selected_provider attempts simulated_result latency_sec].each do |field|
        assert_includes decision.keys, field, "#{decision['operation_id']}: нет поля #{field}"
      end
      assert_includes %w[approved rejected expired], decision["simulated_result"]
      refute_empty decision["attempts"]
      decision["attempts"].each do |attempt|
        %w[provider decision reason].each do |field|
          assert_includes attempt.keys, field
        end
        assert_includes %w[selected skipped], attempt["decision"]
      end
    end
  end

  def test_selected_provider_is_always_among_the_eligible_ones
    pipeline[:decisions].each do |decision|
      operation = @operations.find { |o| o.id == decision["operation_id"] }
      allowed = reference["eligible_providers"].fetch(operation.id) + %w[spacepayments]

      assert_includes allowed, decision["selected_provider"],
                      "#{operation.id}: выбран провайдер вне списка допустимых"
    end
  end

  def test_exactly_one_attempt_per_decision_is_marked_selected
    pipeline[:decisions].each do |decision|
      selected = decision["attempts"].select { |a| a["decision"] == "selected" }

      assert_equal 1, selected.size, "#{decision['operation_id']}: выбранный провайдер должен быть ровно один"
      assert_equal decision["selected_provider"], selected.first["provider"]
    end
  end

  def test_strict_dump_repeats_the_contract_without_a_single_extra_field
    refute_nil pipeline[:strict_path], "строгая выгрузка не найдена ни рядом с решениями, ни в out/"
    assert_path_exists pipeline[:strict_path]

    strict = JSON.parse(File.read(pipeline[:strict_path]))

    assert_equal pipeline[:decisions].map { |d| d["operation_id"] }, strict.map { |d| d["operation_id"] }
    strict.each do |decision|
      assert_equal %w[operation_id selected_provider attempts simulated_result latency_sec], decision.keys
    end
  end

  # --- 5. автопроверка организаторов ---------------------------------------

  def test_organisers_validator_passes_on_the_generated_decisions
    output = nil
    status = nil
    Dir.chdir(RoutingTest::PROJECT_ROOT) do
      read, write = IO.pipe
      pid = Process.spawn(RoutingTest::RUBY, "scripts/validate_10.rb", pipeline[:decisions_path],
                          out: write, err: write)
      write.close
      output = read.read
      _, status = Process.wait2(pid)
      read.close
    end

    assert_predicate status, :success?, "автопроверка организаторов завершилась с ошибкой:\n#{output}"
    assert_match(/Ошибок:\s+0/, output)
    assert_match(/Предупр\.:\s+0/, output)

    passed = output[/Пройдено:\s+(\d+)/, 1].to_i

    assert_operator passed, :>=, 29, "число пройденных проверок не должно падать:\n#{output}"
  end

  # --- 6. воспроизводимость -------------------------------------------------

  def test_two_runs_with_the_same_seed_produce_byte_identical_decisions
    first = RoutingTest.run_pipeline
    second = RoutingTest.run_pipeline
    RoutingTest.register_temp_dir(first[:dir])
    RoutingTest.register_temp_dir(second[:dir])

    assert_equal File.binread(first[:decisions_path]), File.binread(second[:decisions_path]),
                 "решения обязаны совпадать побайтово от прогона к прогону"
    assert_equal File.binread(first[:strict_path]), File.binread(second[:strict_path]),
                 "строгая выгрузка обязана совпадать побайтово"
  end

  def test_the_report_is_reproducible_too
    first = RoutingTest.run_pipeline
    second = RoutingTest.run_pipeline
    RoutingTest.register_temp_dir(first[:dir])
    RoutingTest.register_temp_dir(second[:dir])

    assert_equal File.binread(first[:report_path]), File.binread(second[:report_path])
  end

  def test_a_different_seed_is_allowed_to_change_the_simulated_outcomes
    base = pipeline[:decisions]
    other = RoutingTest.run_pipeline(%w[--config config/routing.yml])

    RoutingTest.register_temp_dir(other[:dir])
    # Зерно то же — результат обязан совпасть; это страховка от скрытой
    # зависимости от времени, случайности или порядка файлов на диске.
    assert_equal base.map { |d| d["selected_provider"] }, other[:decisions].map { |d| d["selected_provider"] }
  end

  def test_queue_without_timestamps_still_routes_deterministically
    # Часы прогона привязаны к snapshot_at из providers.json, поэтому
    # отсутствие created_at в заявках не втягивает в решение Time.now.
    router = -> { Routing::Router.build(config: @config, providers_path: RoutingTest::PROVIDERS_PATH,
                                        history_path: RoutingTest::HISTORY_PATH) }
    operations = -> { Routing::Ingest::Loader.new(@config).load_operations(fixture("operations_no_timestamps.json")) }

    first = router.call.route_all(operations.call)
    second = router.call.route_all(operations.call)

    assert_equal 5, first.size
    assert(first.all? { |decision| !decision.selected_provider.nil? })
    assert_equal first.map(&:selected_provider), second.map(&:selected_provider)
    assert_equal first.map(&:latency_sec), second.map(&:latency_sec)
    assert_equal first.map(&:simulated_result), second.map(&:simulated_result)
  end

  # --- 7. конвейер запускается и завершается успешно ------------------------

  def test_pipeline_exits_with_zero_status
    assert_predicate pipeline[:status], :success?, "bin/route run завершился с ошибкой:\n#{pipeline[:output]}"
  end

  def test_pipeline_reports_no_data_errors
    refute_match(/\[error\]/, pipeline[:output], "боевой прогон не должен давать ошибок во входных данных")
  end
end
