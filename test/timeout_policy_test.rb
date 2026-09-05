# frozen_string_literal: true

require_relative "test_helper"

# Что считать таймаутом — единственное место, где текст ТЗ и практика
# организаторов расходятся прямо.
#
# ТЗ: «при отказе/таймауте — исключить провайдера из пула и выбрать
# следующего». Разбор кейса: таймаут не отказ, до статус-чека заявка
# считается принятой, повторно её никуда не отправляют — иначе можно
# заплатить дважды.
#
# Оба прочтения оставлены рабочими, переключаются одной настройкой.
# По умолчанию — практика: цена ошибки несимметрична. Не добрать долю
# партнёра неприятно, отправить выплату дважды — дорого.
class TimeoutPolicyTest < Minitest::Test
  include RoutingTest

  # У alwaysfails конверсия 0 и все неудачи — таймауты, у backup конверсия 1.
  # Что бы ни выпало генератору, первая попытка всегда истекает по сроку.
  PROVIDERS = File.join(RoutingTest::FIXTURES_DIR, "providers_timeout.json")

  QUEUE = (1..6).map do |i|
    { "operation_id" => format("op_%02d", i),
      "created_at" => (Time.utc(2026, 7, 30, 6, 0, 0) + (i * 120)).iso8601,
      "amount" => 5000, "bank" => "sberbank" }
  end.freeze

  def test_default_policy_is_the_one_from_the_case_review
    config = Routing::Config.load(RoutingTest::CONFIG_PATH)

    assert_equal "pending_success", config.fetch("run", "timeout_policy"),
                 "по умолчанию таймаут не считается отказом — так ответили организаторы"
  end

  # Главное свойство: заявка остаётся у того, кто не ответил. Отправить её
  # второму провайдеру значило бы допустить двойную выплату.
  def test_timeout_does_not_move_the_operation_to_another_provider
    decisions = route("pending_success")
    timed_out = decisions.select { |d| d.cascade_path.first["provider"] == "alwaysfails" }

    refute_empty timed_out, "часть заявок обязана попасть на провайдера, который не отвечает"
    timed_out.each do |decision|
      assert_equal "alwaysfails", decision.selected_provider,
                   "таймаут не отказ: заявка обязана остаться у того, кто не ответил"
      assert_equal 1, decision.cascade_path.size, "второй попытки быть не должно"
      assert_equal "expired", decision.cascade_path.first["outcome"]
    end
  end

  # Буквальное чтение ТЗ включается одним словом и обязано менять маршрут.
  def test_literal_reading_of_the_spec_is_one_word_away
    decisions = route("retry_next")
    cascaded = decisions.select { |d| d.cascade_path.first["provider"] == "alwaysfails" }

    refute_empty cascaded
    cascaded.each do |decision|
      refute_equal "alwaysfails", decision.selected_provider,
                   "по букве ТЗ таймаут исключает провайдера и каскад идёт дальше"
      assert_operator decision.cascade_path.size, :>, 1,
                      "в хронологии обязаны остаться обе попытки"
    end
  end

  # «Считается успехом» означает, что деньги считаются ушедшими: иначе
  # таймауты не расходовали бы дневной лимит, и партнёр незаметно взял бы
  # больше оговорённого.
  def test_pending_operation_consumes_the_daily_limit
    router, decisions = run_with("pending_success")
    state = router.fleet["alwaysfails"]
    taken = decisions.count { |d| d.selected_provider == "alwaysfails" }

    assert_operator taken, :>, 0
    assert_equal taken, state.pending_count
    assert_equal taken * 5000.0, state.daily_amount.to_major.to_f,
                 "заявка, которая считается успешной до статус-чека, обязана занимать дневной лимит"
  end

  # Но слот и реквизит освобождаются: в проде незавершённую выплату закрывает
  # статус-чек, которого в модели нет, и держать их до конца прогона значило бы
  # запереть партнёра намертво после нескольких таймаутов.
  def test_pending_operation_releases_the_slot_and_the_requisite
    state = routed_fleet("pending_success")["alwaysfails"]

    assert_equal 0, state.in_progress_count, "слот обязан освободиться"
    assert_equal 50, state.available_requisites, "реквизит обязан вернуться"
    assert_operator state.pending_count, :>, 0, "и при этом заявки действительно были незавершёнными"
  end

  # И это не отказ: партнёра, который, возможно, всё сделал правильно,
  # нельзя наказывать понижением здоровья.
  def test_timeout_does_not_hurt_provider_health
    pending = routed_fleet("pending_success")["alwaysfails"]
    retried = routed_fleet("retry_next")["alwaysfails"]

    assert_in_delta 1.0, pending.health, 1e-9, "таймаут не портит здоровье провайдера"
    assert_operator retried.health, :<, 1.0, "а вот отказ — портит"
  end

  private

  def config_for(policy)
    Routing::Config.load(RoutingTest::CONFIG_PATH)
                   .merge("run" => { "timeout_policy" => policy },
                          "simulation" => { "expired_share_of_failures" => 1.0, "history_weight" => 0.0 })
  end

  def run_with(policy)
    config = config_for(policy)
    router = Routing::Router.build(config: config, providers_path: PROVIDERS)
    dir = Dir.mktmpdir("timeout-policy-")
    path = File.join(dir, "queue.json")
    File.write(path, JSON.pretty_generate(QUEUE))
    operations = Routing::Ingest::Loader.new(config, issues: router.issues).load_operations(path)
    [router, router.route_all(operations)]
  ensure
    FileUtils.remove_entry(dir, true) if dir
  end

  def route(policy) = run_with(policy).last
  def routed_fleet(policy) = run_with(policy).first.fleet
end
