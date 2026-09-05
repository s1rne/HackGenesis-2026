# frozen_string_literal: true

require_relative "test_helper"

# Сверка с моделью проверяющего и поведение при исчерпанной ёмкости.
#
# Самый дорогой класс ошибок в этом кейсе не виден ни в одной проверке формы:
# файл валиден, все заявки покрыты, поля на месте — а выбранный провайдер
# расходится с тем, кого считает допустимым скрипт организаторов. Причина
# в том, что он считает по снимку, а роутер — по накопленному состоянию.
#
# Разойтись при этом можно двумя способами, и разница между ними принципиальна.
# Расхождение без причины — ошибка. Расхождение, потому что партнёр исчерпал
# дневной лимит в ходе прогона, — следствие ТЗ, которое требует обновлять
# оборот после каждой заявки, и оно обязано быть записано тревогой.
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

  # Исчерпанный дневной лимит — жёсткое ограничение, а не пожелание: ТЗ
  # перечисляет его среди hard-constraints и дальше говорит прямо, что при
  # пустом пуле заявка уходит на self-провайдера. Проверяем, что так и есть.
  def test_exhausted_capacity_sends_the_operation_to_the_self_provider
    with_queue(EXHAUSTING_QUEUE) do |queue_path|
      run = run_pipeline(["--queue", queue_path])
      decisions = JSON.parse(File.read(run[:decisions_path]))
      chosen = decisions.map { |d| d["selected_provider"] }.tally

      assert_operator chosen.fetch("payflow", 0), :>, 0, "пока ёмкость есть, заявки берёт payflow"
      assert_operator chosen.fetch("spacepayments", 0), :>, 0,
                      "когда дневной лимит выбран, заявка обязана уйти на собственного провайдера"
    end
  end

  # Уход на себя не должен быть тихим: иначе в отчёте выйдет ровное
  # распределение, а то, что у партнёра кончились деньги, не увидит никто.
  def test_capacity_alarm_is_raised_and_reaches_the_report
    with_queue(EXHAUSTING_QUEUE) do |queue_path|
      run = run_pipeline(["--queue", queue_path])
      decisions = JSON.parse(File.read(run[:decisions_path]))
      alarms = decisions.flat_map { |d| d["events"].select { |e| e["type"] == "capacity_alarm" } }

      refute_empty alarms, "уход на себя по исчерпанной ёмкости обязан быть записан тревогой"
      first = alarms.first

      assert_includes first["providers"], "payflow", "тревога обязана называть партнёра"
      assert_equal "daily_limit_exceeded", first["blocked_by"].first["constraint"],
                   "тревога обязана называть упёршееся ограничение"

      report = JSON.parse(File.read(run[:report_path]))
      section = report["capacity_alarms"]

      refute_nil section, "отчёт обязан показывать тревоги отдельным разделом"
      assert_operator section["operations"], :>, 0
      assert_operator section["amount_diverted"], :>, 0
      assert_equal alarms.size, section["operations"]
      assert_operator section.dig("by_provider", "payflow", "operations"), :>, 0
    end
  end

  # Сверка обязана отличать объяснённое расхождение от ошибки. Здесь оно
  # объяснено: партнёр исчерпал лимит в ходе прогона, тревога записана.
  def test_the_grader_divergence_is_explained_by_the_capacity_alarm
    result = route_with_policy("fallback")

    assert_empty result.deterministic_missed,
                 "расхождение по исчерпанной ёмкости объяснено тревогой и ошибкой не считается"
    refute_empty result.explained,
                 "и при этом оно обязано быть видно отдельным списком, а не пропасть"
  end

  # Обратная проверка: без тревоги то же расхождение обязано считаться ошибкой.
  # Иначе объяснение превращается в способ замолчать что угодно.
  def test_a_divergence_without_an_alarm_is_still_an_error
    result = route_with_policy("fallback", strip_events: true)

    refute_empty result.deterministic_missed,
                 "решение без тревоги не объясняет ничего — расхождение обязано остаться ошибкой"
  end

  private

  # Прогон исчерпывающей очереди с заданной политикой и сверка с моделью
  # проверяющего. strip_events убирает события из решений — так проверяется,
  # что объяснением служит именно записанная тревога, а не сам факт ухода.
  def route_with_policy(policy, strip_events: false)
    config = Routing::Config.load(RoutingTest::CONFIG_PATH)
                            .merge("run" => { "capacity_exhausted_policy" => policy })
    router = Routing::Router.build(config: config,
                                   providers_path: RoutingTest::PROVIDERS_PATH,
                                   history_path: RoutingTest::HISTORY_PATH)

    with_queue(EXHAUSTING_QUEUE) do |queue_path|
      operations = Routing::Ingest::Loader.new(config, issues: router.issues).load_operations(queue_path)
      decisions = router.route_all(operations)
      decisions = decisions.map { |d| DecisionStub.new(d.operation, d.selected_provider) } if strip_events
      providers = JSON.parse(File.read(RoutingTest::PROVIDERS_PATH))["providers"]

      Routing::GraderCheck.run(operations: operations, decisions: decisions, providers: providers)
    end
  end

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
