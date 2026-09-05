# frozen_string_literal: true

require_relative "test_helper"

# Профили — главное доказательство того, что поведение задаётся настройками,
# а не кодом. Но на выданной очереди половина профилей давала ровно то же
# распределение, что и базовый: жёсткие ограничения там настолько узкие, что
# почти на каждой заявке допустим один провайдер, и спорить целям не о чем.
#
# Со стороны это неотличимо от «настройки не работают». Поэтому есть очередь,
# где допустимы сразу трое, и на ней каждый профиль обязан разойтись с базовым.
# Если однажды перестанет — тест упадёт, и мы узнаем об этом раньше жюри.
class ProfilesTest < Minitest::Test
  include RoutingTest

  QUEUE = File.join(RoutingTest::FIXTURES_DIR, "profile_demo_queue.json")

  def test_the_demo_queue_really_leaves_a_choice
    routes = routes_for("balanced")

    assert_equal 12, routes.size
    assert_operator routes.values.uniq.size, :>=, 3,
                    "на этой очереди должны участвовать минимум три провайдера"
  end

  def test_every_profile_diverges_from_the_baseline
    baseline = routes_for("balanced")

    Routing::Config.load(RoutingTest::CONFIG_PATH).profiles.each do |profile|
      diverged = routes_for(profile).count { |id, provider| baseline[id] != provider }

      assert_operator diverged, :>, 0,
                      "профиль #{profile} не изменил ни одной заявки — " \
                      "либо он настроен впустую, либо очередь перестала оставлять выбор"
    end
  end

  # Смена приоритета обязана менять маршрут — иначе цель cascade_priority
  # существует только на бумаге.
  def test_priority_alone_changes_the_route
    straight = routes_for("cascade_only")
    reversed = routes_for("cascade_only", providers: with_reversed_priority)

    refute_equal straight, reversed,
                 "порядок каскада задаётся полем priority, и его смена обязана менять выбор"
  end

  private

  OVERLAYS = File.join(RoutingTest::PROJECT_ROOT, "config", "provider_overlays.yml")

  # Ровно та же сборка, что и у bin/route: профиль, затем накладка с полями,
  # выведенными из истории. Иначе тест мерил бы конфигурацию, которой ни один
  # прогон не пользуется.
  def routes_for(profile, providers: RoutingTest::PROVIDERS_PATH)
    config = Routing::Config.load(RoutingTest::CONFIG_PATH)
    config = config.with_profile(profile) unless profile == "balanced"
    overlay = YAML.safe_load_file(OVERLAYS, permitted_classes: [Date, Time], aliases: true) || {}
    config = config.merge("ingest" => { "provider_overlays" => overlay["providers"] })
    router = Routing::Router.build(config: config, providers_path: providers,
                                   history_path: RoutingTest::HISTORY_PATH)
    operations = Routing::Ingest::Loader.new(config, issues: router.issues).load_operations(QUEUE)

    router.route_all(operations).to_h { |decision| [decision.operation.id, decision.selected_provider] }
  end

  # Тот же файл провайдеров, но порядок приоритетов перевёрнут.
  def with_reversed_priority
    payload = JSON.parse(File.read(RoutingTest::PROVIDERS_PATH))
    payload["providers"].each do |provider|
      next if provider["priority"].nil? || provider["priority"] > 90

      provider["priority"] = 4 - provider["priority"]
    end
    path = File.join(Dir.mktmpdir("profiles-"), "providers.json")
    File.write(path, JSON.pretty_generate(payload))
    path
  end
end
