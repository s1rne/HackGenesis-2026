# frozen_string_literal: true

require_relative "test_helper"

# По кому считается фактическая доля трафика.
#
# Вопрос задавали организаторам на Q&A-сессии, и ответ пришёл письменно:
# считать по итоговому selected_provider после fallback — по тому, кто реально
# принял заявку, а не по первой неудачной попытке. Горизонт для сдачи —
# выданная очередь; история идёт на калибровку и аналитику, но в знаменатель
# доли не подмешивается.
#
# Это не наше решение и не предмет вкуса, поэтому оно закреплено тестом:
# случайная правка счётчика доли ломает соответствие правилам кейса.
class TrafficShareBasisTest < Minitest::Test
  include RoutingTest

  def test_share_counts_the_final_provider_not_the_first_attempt
    run = failover_run
    decisions = JSON.parse(File.read(run[:decisions_path]))
    moved = decisions.select { |d| d.dig("cascade", "path").map { |s| s["provider"] }.uniq.size > 1 }

    refute_empty moved, "нужен прогон, где каскад реально уходит к другому провайдеру"

    by_final = decisions.group_by { |d| d["selected_provider"] }.transform_values(&:size)
    by_first = decisions.group_by { |d| d.dig("cascade", "path", 0, "provider") }.transform_values(&:size)
    refute_equal by_first, by_final, "иначе проверка не различает две трактовки"

    reported = JSON.parse(File.read(run[:report_path]))["distribution"]
                   .transform_values { |row| row["count"] }
                   .reject { |_, count| count.zero? }

    assert_equal by_final.reject { |_, c| c.zero? }, reported,
                 "доля обязана считаться по итоговому провайдеру"
  end

  def test_the_provider_that_only_failed_an_attempt_gets_no_share_for_it
    run = failover_run
    decisions = JSON.parse(File.read(run[:decisions_path]))
    decision = decisions.find do |d|
      d.dig("cascade", "path").map { |s| s["provider"] }.uniq.size > 1
    end
    first = decision.dig("cascade", "path", 0, "provider")
    final = decision["selected_provider"]
    refute_equal first, final

    counted = JSON.parse(File.read(run[:report_path])).dig("distribution", first, "count")
    also_final = decisions.count { |d| d["selected_provider"] == first }

    assert_equal also_final, counted,
                 "провайдеру засчитываются только те заявки, которые он в итоге принял"
  end

  # Знаменатель — выданная очередь. Сто операций истории в него не входят,
  # иначе доли посыпались бы в десять раз.
  def test_horizon_is_the_queue_not_the_history
    report = pipeline[:report]

    assert_equal RoutingTest.queue_rows.size, report["total_operations"]
    assert_equal report["total_operations"],
                 report["distribution"].values.sum { |row| row["count"] },
                 "сумма долей обязана сходиться с числом заявок очереди"
    assert_equal 100, report.dig("history_baseline", "operations"),
                 "история читается — но отдельно, как калибровка"
  end

  def test_history_is_used_for_calibration_not_for_the_share_denominator
    report = pipeline[:report]
    shares = report["distribution"].values.sum { |row| row["share_pct"].to_f }

    assert_in_delta 100.0, shares, 0.2, "доли считаются от очереди и дают в сумме сто процентов"
    refute_nil report.dig("history_baseline", "providers"), "калибровка по истории остаётся в отчёте"
  end

  private

  def failover_run
    @failover_run ||= run_pipeline(["--profile", "failover_demo"])
  end
end
