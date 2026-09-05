# frozen_string_literal: true

require_relative "test_helper"

# Лимит партнёра задан в деньгах, а целевая доля — в заявках. Из этого следует
# неочевидное: партнёр может выбрать дневной лимит целиком и всё равно недобрать
# свою долю, если ему достались крупные чеки. Те же деньги на мелких выплатах
# дали бы больше заявок.
#
# Разрыв виден точно, потому что потолок по ёмкости в разделе достижимости
# считается жадным набором самых дешёвых допустимых заявок в пределах
# свободного лимита. Факт ниже потолка означает, что деньги ушли на чеки
# крупнее, чем следовало.
#
# Очередь на шестьдесят заявок с разбросом сумм от 900 до 180 000 ₽:
# на ней payflow упирается в свободные 100 000 ₽ дневного лимита.
class CapacityEfficiencyTest < Minitest::Test
  include RoutingTest

  QUEUE = File.join(RoutingTest::FIXTURES_DIR, "capacity_pressure_queue.json")

  def setup
    @run = run_pipeline(["--queue", QUEUE])
    @report = JSON.parse(File.read(@run[:report_path]))
  end

  def test_payflow_really_runs_out_of_money
    utilization = @report.dig("projected_daily_utilization", "payflow", "utilization_pct")

    assert_operator utilization, :>=, 95.0, "иначе тест проверяет не тот сценарий"
  end

  # Потолок по ёмкости обязан быть выше факта: значит, теми же деньгами
  # можно было взять больше заявок.
  def test_the_capacity_ceiling_is_above_the_actual_share
    ceiling = @report.dig("target_achievability", "bounds", "payflow", "ceiling_pct").to_f
    actual = @report.dig("distribution", "payflow", "share_pct").to_f

    assert_operator ceiling, :>, actual + 2.0
  end

  # И это должно быть сказано вслух — рекомендацией с конкретным параметром,
  # а не остаться числом, которое надо самому заметить и самому истолковать.
  def test_the_report_says_it_out_loud
    rec = Array(@report["recommendations_detailed"])
          .find { |item| item["parameter"] == "providers.payflow.limit_amount_max" }

    refute_nil rec, "разрыв между потолком по ёмкости и фактом обязан попадать в рекомендации"
    assert_match(/теми же деньгами/, rec["text"])
    assert_match(/потолок по ёмкости/, rec["text"])
    assert_equal "high", rec["priority"]
  end

  # Обратная проверка: на публичной очереди никто не упирается в лимит,
  # и рекомендации быть не должно. Иначе она появлялась бы всегда и ничего
  # не значила.
  def test_no_such_recommendation_when_nobody_is_capacity_bound
    report = JSON.parse(File.read(RoutingTest.pipeline[:report_path]))
    parameters = Array(report["recommendations_detailed"]).map { |item| item["parameter"] }

    refute_includes parameters, "providers.payflow.limit_amount_max"
  end
end
