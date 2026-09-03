# frozen_string_literal: true

# Общая обвязка тестов.
#
# Никаких гемов и Bundler: minitest берётся из стандартной библиотеки,
# библиотека роутинга подключается напрямую из lib/.
#
#   rake test
#   ruby -Ilib -Itest test/cascade_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "routing"

module RoutingTest
  PROJECT_ROOT = File.expand_path("..", __dir__)
  DATA_DIR = File.join(PROJECT_ROOT, "data")
  FIXTURES_DIR = File.join(__dir__, "fixtures")
  CONFIG_PATH = File.join(PROJECT_ROOT, "config", "routing.yml")
  PROVIDERS_PATH = File.join(DATA_DIR, "providers.json")
  QUEUE_PATH = File.join(DATA_DIR, "operations_queue_10.json")
  HISTORY_PATH = File.join(DATA_DIR, "operations_history.csv")
  REFERENCE_PATH = File.join(DATA_DIR, "reference_decisions.json")

  # Интерпретатор, которым запущены сами тесты: дочерние прогоны bin/route
  # обязаны идти тем же ruby, иначе тест поймает системный 2.6.
  RUBY = RbConfig.ruby

  module_function

  def fixture(name) = File.join(FIXTURES_DIR, name)

  def reference = @reference ||= JSON.parse(File.read(REFERENCE_PATH))
  def queue_rows = @queue_rows ||= JSON.parse(File.read(QUEUE_PATH))
  def providers_payload = @providers_payload ||= JSON.parse(File.read(PROVIDERS_PATH))

  # Один полный прогон конвейера на всю сессию тестов: он занимает доли
  # секунды, но повторять его в каждом тесте незачем.
  def pipeline = @pipeline ||= run_pipeline

  # Запускает bin/route run из корня проекта, складывая выгрузку во временный
  # каталог. Пути к входным данным остаются умолчаниями CLI — так тест
  # проверяет ровно тот конвейер, который сдаётся организаторам.
  def run_pipeline(extra_args = [])
    dir = Dir.mktmpdir("routing-test-")
    # Имя выгрузки уникально: CLI кладёт строгий вариант в общий каталог out/
    # рядом с проектом, и два прогона не должны наступать друг на друга.
    stem = "routing_decisions_test_#{Process.pid}_#{(@run_counter = @run_counter.to_i + 1)}"
    decisions_path = File.join(dir, "#{stem}.json")
    report_path = File.join(dir, "routing_report.json")

    output = nil
    status = nil
    Dir.chdir(PROJECT_ROOT) do
      command = [RUBY, "bin/route", "run", "--quiet",
                 "--decisions", decisions_path, "--report", report_path, *extra_args]
      read, write = IO.pipe
      pid = Process.spawn(*command, out: write, err: write)
      write.close
      output = read.read
      _, status = Process.wait2(pid)
      read.close
    end

    {
      dir: dir,
      status: status,
      output: output,
      decisions_path: decisions_path,
      report_path: report_path,
      strict_path: strict_dump_path(decisions_path),
      decisions: JSON.parse(File.read(decisions_path)),
      report: JSON.parse(File.read(report_path))
    }
  end

  # Строгая выгрузка пишется либо рядом с решениями, либо в каталог out/ —
  # тест не должен ломаться от того, где именно CLI решил её положить.
  def strict_dump_path(decisions_path)
    stem = File.basename(decisions_path, ".json")
    candidates = [decisions_path.sub(/\.json\z/, ".strict.json"),
                  File.join(PROJECT_ROOT, "out", "#{stem}.strict.json")]
    found = candidates.find { |path| File.exist?(path) }
    (@stray_files ||= []) << found if found&.start_with?(File.join(PROJECT_ROOT, "out"))
    found
  end

  # Приборка временных каталогов после всей сессии.
  def register_temp_dir(dir)
    (@temp_dirs ||= []) << dir
    dir
  end

  def cleanup_temp_dirs
    Array(@temp_dirs).each { |dir| FileUtils.remove_entry(dir, true) }
    FileUtils.remove_entry(@pipeline[:dir], true) if @pipeline
    Array(@stray_files).each { |path| FileUtils.rm_f(path) }
  end

  # Заглушка цели маршрутизации.
  #
  # Намеренно НЕ наследует Strategies::Base: наследование регистрирует класс
  # в реестре целей, и тестовая заглушка попала бы в общий список наравне
  # с боевыми. Scorer от цели требует только этот набор методов.
  class StubStrategy
    attr_reader :id, :weight, :tier

    def initialize(id, tier: 2, weight: 1.0, scores: {})
      @id = id
      @tier = tier
      @weight = weight
      @scores = scores
    end

    def raw_score(context) = @scores[context.provider.id]
    def explain(context) = "#{@id} по #{context.provider.id}"
    def selection_reason = Routing::Reasons.for_strategy(@id)
  end

  # Заглушка провайдерского ответа: блок решает, что ответит каждый провайдер
  # на каждой попытке. Без неё каскад невозможно проверить детерминированно.
  class StubSimulator
    attr_reader :calls

    def initialize(&block)
      @block = block
      @calls = []
    end

    def respond(operation:, provider:, state:, attempt_no:)
      @calls << [operation.id, provider.id, attempt_no]
      @block.call(provider.id, attempt_no, operation)
    end

    def self.approved(latency: 12) = Routing::Simulator::Response.new(outcome: :approved, latency_sec: latency, refused: false)
    def self.declined(latency: 8) = Routing::Simulator::Response.new(outcome: :rejected, latency_sec: latency, refused: true)
    def self.expired(latency: 540) = Routing::Simulator::Response.new(outcome: :expired, latency_sec: latency, refused: true)
  end

  # Методы, доступные во всех тестах.
  module Helpers
    def project_config = Routing::Config.load(RoutingTest::CONFIG_PATH)
    def default_config = Routing::Config.load(nil)

    def config_with(overrides, base: nil)
      (base || project_config).merge(overrides)
    end

    def record_for(hash, aliases: {})
      Routing::Ingest::Record.new(
        hash,
        field_map: Routing::Ingest::FieldMap.new(aliases),
        issues: Routing::Ingest::Issues.new,
        source: "test"
      )
    end

    # Провайдер строится из сырого хэша тем же путём, что и боевые данные:
    # через Record, чтобы тест заодно проверял приведение типов.
    def build_provider(attributes, defaults: { conversion_24h: 0.8, avg_latency_sec: 30 },
                       bank_aliases: {}, self_provider_ids: [])
      Routing::Provider.from_record(
        record_for(attributes),
        defaults: defaults, bank_aliases: bank_aliases, self_provider_ids: self_provider_ids
      )
    end

    def build_fleet(providers, issues: Routing::Ingest::Issues.new)
      Routing::Fleet.new(providers, issues: issues)
    end

    def build_operation(id: "op_test", amount: 10_000, bank: "sberbank", index: 0, **rest)
      Routing::Operation.new(id: id, amount: amount, bank: bank, index: index, **rest)
    end

    def context_for(provider:, operation:, fleet:, at: 0.0, config: nil, eligible_ids: nil, attempt_no: 1)
      Routing::EvaluationContext.new(
        operation: operation, provider: provider, state: fleet[provider.id], fleet: fleet,
        at: at, config: config || project_config, history: nil, attempt_no: attempt_no,
        excluded: [], eligible_ids: eligible_ids
      )
    end

    # Готовая пара «флот + контекст» для проверки одного ограничения.
    def single_context(provider_attrs, operation_attrs = {}, at: 0.0, config: nil)
      provider = provider_attrs.is_a?(Routing::Provider) ? provider_attrs : build_provider(provider_attrs)
      fleet = build_fleet([provider])
      operation = build_operation(**operation_attrs)
      context_for(provider: provider, operation: operation, fleet: fleet, at: at, config: config)
    end

    def build_cascade(fleet:, config: nil, simulator:, clock: nil)
      config ||= project_config
      Routing::Cascade.new(
        fleet: fleet,
        constraints: Routing::Constraints::Registry.build(config),
        scorer: Routing::Scorer.new(Routing::Strategies::Registry.build(config), config),
        simulator: simulator,
        config: config,
        clock: clock || Routing::Clock.new(started_at: Time.at(1_785_000_000))
      )
    end

    def reference = RoutingTest.reference
    def queue_rows = RoutingTest.queue_rows
    def providers_payload = RoutingTest.providers_payload
    def pipeline = RoutingTest.pipeline
    def fixture(name) = RoutingTest.fixture(name)

    def assert_in_delta_pct(expected, actual, delta = 0.05, message = nil)
      assert_in_delta expected, actual, delta, message
    end
  end
end

Minitest::Test.include(RoutingTest::Helpers)

Minitest.after_run { RoutingTest.cleanup_temp_dirs }
