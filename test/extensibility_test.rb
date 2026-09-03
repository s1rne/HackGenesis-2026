# frozen_string_literal: true

require_relative "test_helper"

# Расширяемость проверяется исполнением, а не обещанием в README.
#
# Утверждение «можно добавить новое правило и новую цель, не трогая базовую
# архитектуру» ничего не стоит, пока его не выполнили. Здесь оно выполняется
# прямо в тесте: два новых класса объявляются на лету, включаются через
# конфигурацию и начинают влиять на маршрутизацию. Ни строчки в lib/ при этом
# не меняется — если бы для расширения понадобилось трогать каскад или скоринг,
# этот тест написать было бы невозможно.
class ExtensibilityTest < Minitest::Test
  # Новое жёсткое ограничение: не отправлять заявки дороже порога провайдерам,
  # у которых нет отдельного соглашения. Правило вымышленное, механизм настоящий.
  class HighValueAgreement < Routing::Constraints::Base
    def check(context)
      threshold = Routing::Money.from_major(setting("threshold", 100_000))
      return skip if context.provider.self_provider?
      return skip if context.operation.amount <= threshold
      return nil if context.provider.allow_negative_agreement

      violation("high_value_agreement_missing",
                "#{context.operation.amount} выше порога #{threshold}, " \
                "а отдельного соглашения у провайдера нет")
    end
  end

  # Новая мягкая цель: предпочитать провайдеров с коротким временем ответа.
  class LatencyPreference < Routing::Strategies::Base
    def raw_score(context)
      latency = context.provider.avg_latency_sec
      latency.nil? ? nil : -latency.to_f
    end

    def explain(context)
      "среднее время ответа #{context.provider.avg_latency_sec} с"
    end
  end

  def setup
    @base = Routing::Config.load(RoutingTest::CONFIG_PATH)
  end

  def test_new_constraint_registers_itself_by_inheritance
    assert_includes Routing::Constraints::Registry.known_ids, "high_value_agreement",
                    "правило должно попасть в реестр самим фактом наследования"
  end

  def test_new_strategy_registers_itself_by_inheritance
    assert_includes Routing::Strategies::Registry.known_ids, "latency_preference"
  end

  def test_new_constraint_changes_routing_when_enabled_in_configuration
    without = route_with({})
    with = route_with("hard_constraints" => {
                        "high_value_agreement" => { "enabled" => true, "threshold" => 100_000 }
                      })

    # op_103 на 150 000 ₽ проходит только через quickpay, а тот не имеет
    # отдельного соглашения — с новым правилом заявке некуда идти, кроме
    # self-провайдера.
    big = ->(list) { list.find { |decision| decision.operation.id == "op_103" } }
    assert_equal "quickpay", big.call(without).selected_provider
    assert_equal "spacepayments", big.call(with).selected_provider,
                 "включённое через конфигурацию правило обязано менять маршрут"

    skipped = big.call(with).attempts.find { |attempt| attempt["reason"] == "high_value_agreement_missing" }
    refute_nil skipped, "причина нового правила должна попадать в attempts как обычная причина"
  end

  def test_new_strategy_participates_in_scoring_when_enabled
    decisions = route_with("strategies" => {
                             "latency_preference" => { "enabled" => true, "tier" => 1, "weight" => 2.0 }
                           })

    selected = decisions.flat_map(&:attempts).find { |attempt| attempt["decision"] == "selected" && attempt["factors"] }
    refute_nil selected, "должна найтись операция с раскладкой скоринга"
    factors = selected["factors"].map { |factor| factor["factor"] }
    assert_includes factors, "latency_preference",
                    "новая цель обязана появиться в раскладке скоринга без правок ядра"
  end

  def test_new_strategy_in_top_tier_shifts_traffic_to_the_fastest_provider
    # quickpay отвечает за 29 с против 38 у vipay и 52 у payflow: если время
    # ответа становится главным, трафик обязан сместиться к нему.
    baseline = distribution(route_with({}))
    tuned = distribution(route_with("strategies" => {
                                      "latency_preference" => { "enabled" => true, "tier" => 1, "weight" => 2.0 }
                                    }))

    assert_operator tuned.fetch("quickpay", 0), :>, baseline.fetch("quickpay", 0),
                    "цель по времени ответа должна перетянуть заявки на самого быстрого"
  end

  def test_unknown_rule_in_configuration_is_reported_not_ignored
    error = assert_raises(Routing::ConfigError) do
      build_router("hard_constraints" => { "no_such_rule" => { "enabled" => true } })
    end
    assert_match(/no_such_rule/, error.message)
  end

  private

  def build_router(overrides)
    Routing::Router.build(config: @base.merge(overrides),
                          providers_path: RoutingTest::PROVIDERS_PATH,
                          history_path: RoutingTest::HISTORY_PATH)
  end

  def route_with(overrides)
    router = build_router(overrides)
    loader = Routing::Ingest::Loader.new(router.config, issues: router.issues)
    router.route_all(loader.load_operations(RoutingTest::QUEUE_PATH))
  end

  def distribution(decisions)
    decisions.group_by(&:selected_provider).transform_values(&:size)
  end
end
