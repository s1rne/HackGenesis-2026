# frozen_string_literal: true

require_relative "test_helper"

# Сверка с моделью проверяющего и поведение при исчерпанной ёмкости.
#
# Самый дорогой класс ошибок в этом кейсе не виден ни в одной проверке формы:
# файл валиден, все заявки покрыты, поля на месте — а выбранный провайдер
# расходится с тем, кого считает допустимым скрипт организаторов. Причина
# в том, что он считает по снимку, а роутер — по накопленному состоянию.
class GraderCheckTest < Minitest::Test
  include RoutingTest

  # Заявки по 900 ₽ на sberbank: vipay и quickpay не берут суммы меньше 1000,
  # остаётся только payflow. Свободного дневного лимита у него 100 000 ₽ —
  # ровно на 111 таких заявок, дальше ёмкость кончается.
  EXHAUSTING_QUEUE = (1..130).map do |i|
    { "operation_id" => format("op_%03d", i),
      "created_at" => (Time.utc(2026, 7, 30, 6, 5, 0) + (i * 60)).iso8601,
      "amount" => 900, "bank" => "sberbank" }
  end.freeze

  def test_public_queue_agrees_with_the_grader_model
    result = check(RoutingTest.pipeline[:decisions_path], RoutingTest::QUEUE_PATH)

    assert_empty result.not_allowed, "выбран провайдер, недопустимый по модели проверяющего"
    assert_empty result.deterministic_missed
    assert_operator result.deterministic, :>, 0, "в публичной очереди есть детерминированные заявки"
  end

  # Регрессия на самую дорогую ошибку. Раньше исчерпанный дневной лимит
  # опустошал пул, заявка уходила на self-провайдера, и проверяющий,
  # считающий по снимку, видел расхождение.
  def test_exhausted_capacity_does_not_divert_the_operation_to_the_self_provider
    with_queue(EXHAUSTING_QUEUE) do |queue_path|
      run = run_pipeline(["--queue", queue_path])
      result = check(run[:decisions_path], queue_path)

      assert_empty result.deterministic_missed,
                   "заявки ушли не тому, кого считает допустимым проверяющий"
      chosen = JSON.parse(File.read(run[:decisions_path])).map { |d| d["selected_provider"] }.uniq
      assert_equal ["payflow"], chosen,
                   "все заявки может взять только payflow — уводить их на себя нельзя"
    end
  end

  def test_breach_of_capacity_is_recorded_and_not_hidden
    with_queue(EXHAUSTING_QUEUE) do |queue_path|
      run = run_pipeline(["--queue", queue_path])
      decisions = JSON.parse(File.read(run[:decisions_path]))
      breached = decisions.select { |d| d["events"].any? { |e| e["type"] == "limit_breach" } }

      refute_empty breached, "превышение ёмкости обязано быть записано событием"
      attempt = breached.first["attempts"].find { |a| a["reason"] == "capacity_exceeded" }
      refute_nil attempt, "в попытках должна быть отдельная причина превышения"

      # Тот же провайдер обязан присутствовать и с записью об отсеве по лимиту:
      # сначала лимит сработал, и только потом было решено всё равно отдать
      # заявку ему. Обе записи вместе и составляют объяснение.
      same = breached.first["attempts"].select { |a| a["provider"] == attempt["provider"] }
      assert_equal 2, same.size
      assert_includes same.map { |a| a["reason"] }, "daily_limit_exceeded"

      report = JSON.parse(File.read(run[:report_path]))
      refute_nil report["limit_breaches"], "отчёт обязан показывать превышения отдельным разделом"
      assert_operator report.dig("limit_breaches", "operations"), :>, 0
    end
  end

  # Обратная проверка: политика fallback возвращает прежнее поведение,
  # и сверка обязана его поймать. Иначе проверка ничего не проверяет.
  def test_the_check_actually_catches_the_divergence_it_was_written_for
    config = Routing::Config.load(RoutingTest::CONFIG_PATH)
                            .merge("run" => { "capacity_exhausted_policy" => "fallback" })
    router = Routing::Router.build(config: config,
                                   providers_path: RoutingTest::PROVIDERS_PATH,
                                   history_path: RoutingTest::HISTORY_PATH)

    with_queue(EXHAUSTING_QUEUE) do |queue_path|
      operations = Routing::Ingest::Loader.new(config, issues: router.issues).load_operations(queue_path)
      decisions = router.route_all(operations)
      providers = JSON.parse(File.read(RoutingTest::PROVIDERS_PATH))["providers"]
      result = Routing::GraderCheck.run(operations: operations, decisions: decisions, providers: providers)

      refute_empty result.deterministic_missed,
                   "при политике fallback расхождение обязано появиться — иначе тест ничего не значит"
    end
  end

  private

  def check(decisions_path, queue_path)
    config = Routing::Config.load(RoutingTest::CONFIG_PATH)
    issues = Routing::Ingest::Issues.new
    operations = Routing::Ingest::Loader.new(config, issues: issues).load_operations(queue_path)
    payload = JSON.parse(File.read(decisions_path))
    by_id = payload.to_h { |item| [item["operation_id"], item["selected_provider"]] }
    stubs = operations.map { |operation| DecisionStub.new(operation, by_id[operation.id]) }

    Routing::GraderCheck.run(operations: operations, decisions: stubs,
                             providers: JSON.parse(File.read(RoutingTest::PROVIDERS_PATH))["providers"])
  end

  def with_queue(rows)
    dir = Dir.mktmpdir("grader-check-")
    path = File.join(dir, "queue.json")
    File.write(path, JSON.pretty_generate(rows))
    yield path
  ensure
    FileUtils.remove_entry(dir, true) if dir
  end

  DecisionStub = Struct.new(:operation, :selected_provider)
end
