# frozen_string_literal: true

require_relative "test_helper"

# Здоровье провайдера и проверка настроек — два механизма, добавленных после
# разбора чекпоинтов: первый отвечает на вопрос «а если партнёр лёг в полдень»,
# второй — на вопрос «а что будет, если конфигурацию заполнят неправильно».
class HealthAndConfigTest < Minitest::Test
  include RoutingTest

  # --- здоровье провайдера ------------------------------------------------

  def test_health_is_full_while_there_are_no_consecutive_failures
    state = state_for
    assert_in_delta 1.0, state.health(0.0), 1e-9
  end

  def test_two_failures_in_a_row_drop_health_to_zero
    state = state_for
    2.times { |i| fail_once(state, at: i.to_f) }

    assert_equal 2, state.consecutive_failures
    assert_in_delta 0.0, state.health(1.0), 1e-9
  end

  def test_a_success_clears_the_streak
    state = state_for
    fail_once(state, at: 0.0)
    operation = build_operation(id: "ok")
    state.reserve(operation, at: 1.0)
    state.settle_approved(operation)

    assert_equal 0, state.consecutive_failures
    assert_in_delta 1.0, state.health(1.0), 1e-9
  end

  # Отказ пятиминутной давности говорит о партнёре меньше, чем отказ
  # секунду назад, поэтому здоровье восстанавливается со временем.
  def test_health_recovers_over_time
    state = state_for
    2.times { |i| fail_once(state, at: i.to_f) }

    just_now = state.health(1.0, recovery_sec: 300.0)
    halfway = state.health(151.0, recovery_sec: 300.0)
    later = state.health(400.0, recovery_sec: 300.0)

    assert_operator halfway, :>, just_now
    assert_operator later, :>, halfway
    assert_in_delta 1.0, later, 1e-9
  end

  # Ключевое свойство: это цель, а не жёсткое ограничение. Больной провайдер
  # уходит в конец очереди, но не исчезает — иначе аварийный выключатель мог
  # бы отрезать последний оставшийся маршрут.
  def test_unhealthy_provider_loses_priority_but_stays_available
    healthy = build_provider({ "payment_system" => "healthy", "traffic_percentage" => 50 })
    sick = build_provider({ "payment_system" => "sick", "traffic_percentage" => 50 })
    fleet = build_fleet([healthy, sick])
    2.times { |i| fail_once(fleet["sick"], at: i.to_f) }

    strategy = Routing::Strategies::ProviderHealth.new("failures_to_zero" => 2, "recovery_sec" => 300)
    operation = build_operation
    scores = [healthy, sick].map do |provider|
      strategy.raw_score(context_for(provider: provider, operation: operation, fleet: fleet, at: 2.0))
    end

    assert_operator scores.first, :>, scores.last, "здоровый обязан идти впереди больного"
    assert_includes 0.0..1.0, scores.last, "больной не исключается, он просто оказывается ниже"
  end

  def test_health_explains_itself_with_numbers
    fleet = build_fleet([build_provider({ "payment_system" => "sick", "traffic_percentage" => 100 })])
    2.times { |i| fail_once(fleet["sick"], at: i.to_f) }
    strategy = Routing::Strategies::ProviderHealth.new({})
    note = strategy.explain(context_for(provider: fleet.providers.first, operation: build_operation,
                                        fleet: fleet, at: 10.0))

    assert_match(/2 отказа подряд/, note)
    assert_match(/здоровье/, note)
  end

  # --- проверка настроек ---------------------------------------------------

  def test_unknown_scoring_mode_is_refused_before_the_run
    error = assert_raises(Routing::ConfigError) { load_config("scoring" => { "mode" => "bananas" }) }
    assert_match(/bananas/, error.message)
    assert_match(/lexicographic_weighted/, error.message, "сообщение обязано называть допустимые значения")
  end

  def test_negative_epsilon_is_refused
    error = assert_raises(Routing::ConfigError) { load_config("scoring" => { "tier_epsilon" => -5 }) }
    assert_match(/tier_epsilon/, error.message)
  end

  def test_negative_weight_is_refused
    error = assert_raises(Routing::ConfigError) do
      load_config("strategies" => { "conversion" => { "enabled" => true, "weight" => -1 } })
    end
    assert_match(/conversion/, error.message)
  end

  def test_unknown_exhausted_policy_is_refused
    error = assert_raises(Routing::ConfigError) do
      load_config("run" => { "exhausted_pool_policy" => "teleport" })
    end
    assert_match(/teleport/, error.message)
  end

  def test_all_problems_are_reported_at_once_not_one_by_one
    error = assert_raises(Routing::ConfigError) do
      load_config("scoring" => { "mode" => "bananas", "tier_epsilon" => -5 })
    end

    assert_match(/mode/, error.message)
    assert_match(/tier_epsilon/, error.message, "чинить настройки по одной ошибке за прогон — мучение")
  end

  def test_the_project_configuration_passes_its_own_validation
    Routing::Config.load(RoutingTest::CONFIG_PATH).validate!
    Routing::Config.load(RoutingTest::CONFIG_PATH).profiles.each do |name|
      Routing::Config.load(RoutingTest::CONFIG_PATH).with_profile(name).validate!
    end
  end

  private

  def state_for
    build_fleet([build_provider({ "payment_system" => "p", "traffic_percentage" => 100 })])["p"]
  end

  def fail_once(state, at:)
    operation = build_operation(id: "op_#{at}")
    state.reserve(operation, at: at)
    state.settle_failed(operation, :rejected, at: at)
  end

  def load_config(overrides)
    dir = Dir.mktmpdir("config-test-")
    path = File.join(dir, "routing.yml")
    base = YAML.safe_load_file(RoutingTest::CONFIG_PATH, permitted_classes: [Date, Time], aliases: true)
    File.write(path, YAML.dump(Routing::Config.deep_merge(base, Routing::Config.stringify(overrides))))
    Routing::Config.load(path)
  ensure
    FileUtils.remove_entry(dir, true) if dir
  end
end
