# frozen_string_literal: true

require_relative "test_helper"

# Итоговая аналитика.
#
# Отчёт проверяется на боевом прогоне, а не на выдуманных решениях: смысл
# проверки в том, что агрегаты сходятся с выгрузкой решений. Отчёт, который
# не сходится с decisions, хуже отсутствующего — по нему делают выводы.
class ReportTest < Minitest::Test
  REQUIRED_KEYS = %w[
    period total_operations distribution skip_reasons projected_daily_utilization recommendations
  ].freeze

  def report = pipeline[:report]
  def decisions = pipeline[:decisions]

  # --- обязательный минимум из ТЗ ------------------------------------------

  def test_report_contains_every_key_required_by_the_statement_of_work
    REQUIRED_KEYS.each do |key|
      assert_includes report.keys, key, "в отчёте нет обязательного раздела #{key}"
    end
  end

  def test_period_is_a_date
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, report["period"])
  end

  def test_total_operations_matches_the_queue_and_the_decisions
    assert_equal queue_rows.size, report["total_operations"]
    assert_equal decisions.size, report["total_operations"]
  end

  def test_distribution_has_a_row_for_every_provider_with_count_share_and_target
    assert_equal %w[vipay payflow quickpay spacepayments], report["distribution"].keys

    report["distribution"].each do |id, row|
      %w[count share_pct target_pct deviation_pct].each do |field|
        assert_includes row.keys, field, "у #{id} в distribution нет поля #{field}"
      end
      assert_in_delta row["share_pct"] - row["target_pct"], row["deviation_pct"], 0.11,
                      "отклонение должно быть разностью факта и цели"
    end
  end

  def test_distribution_shares_add_up_to_one_hundred_percent
    total = report["distribution"].values.sum { |row| row["share_pct"] }

    assert_in_delta 100.0, total, 0.5, "доли по количеству должны складываться в 100%"
  end

  def test_distribution_targets_add_up_to_one_hundred_percent
    total = report["distribution"].values.sum { |row| row["target_pct"] }

    assert_in_delta 100.0, total, 0.5, "целевые доли нормализованы к 100%"
  end

  def test_distribution_counts_match_the_selected_providers_in_decisions
    expected = decisions.group_by { |d| d["selected_provider"] }.transform_values(&:size)

    report["distribution"].each do |id, row|
      assert_equal expected.fetch(id, 0), row["count"], "количество по #{id} расходится с решениями"
    end
    assert_equal decisions.size, report["distribution"].values.sum { |row| row["count"] },
                 "каждая заявка учтена ровно один раз"
  end

  def test_skip_reasons_add_up_to_the_number_of_skipped_attempts
    skipped = decisions.sum { |d| d["attempts"].count { |a| a["decision"] == "skipped" } }

    assert_equal skipped, report["skip_reasons"].values.sum,
                 "агрегат причин обязан сходиться с числом skipped-записей в решениях"
  end

  def test_every_skip_reason_is_a_code_from_the_catalog
    report["skip_reasons"].each_key do |code|
      assert Routing::Reasons.known?(code), "причина #{code} не описана в каталоге"
      refute_empty Routing::Reasons.text(code)
    end
  end

  def test_skip_reasons_are_sorted_by_frequency
    counts = report["skip_reasons"].values

    assert_equal counts.sort.reverse, counts, "самые частые причины стоят первыми"
  end

  def test_projected_daily_utilization_reports_used_limit_and_percentage
    report["projected_daily_utilization"].each do |id, row|
      assert_includes row.keys, "used", "у #{id} нет фактического оборота"
      assert_includes row.keys, "utilization_pct"
      next if row["limit"].nil?

      assert_in_delta row["used"].to_f / row["limit"] * 100, row["utilization_pct"], 0.11
      assert_operator row["utilization_pct"], :<=, 100.0, "оборот #{id} не должен выходить за дневной лимит"
    end
  end

  def test_projected_utilization_grows_only_by_the_amounts_routed_in_this_run
    initial = providers_payload["providers"].to_h { |p| [p["payment_system"], p["daily_approved_amount"].to_f] }

    report["projected_daily_utilization"].each do |id, row|
      added = row["used"].to_f - initial.fetch(id, 0.0)

      assert_operator added, :>=, -0.001, "дневной оборот #{id} не может уменьшиться"
      assert_in_delta added, row["added_this_run"].to_f, 0.01 if row.key?("added_this_run")
    end
  end

  def test_recommendations_are_a_list_of_readable_strings
    assert_kind_of Array, report["recommendations"]
    refute_empty report["recommendations"]
    report["recommendations"].each do |text|
      assert_kind_of String, text
      refute_empty text.strip
    end
  end

  def test_detailed_recommendations_name_a_concrete_parameter
    detailed = report["recommendations_detailed"]

    refute_nil detailed, "рекомендация без параметра неприменима: по ней нечего сделать"
    refute_empty detailed
    detailed.each do |item|
      assert_includes item.keys, "parameter"
      assert_includes item.keys, "evidence"
      assert_includes %w[high medium low], item["priority"]
    end
  end

  def test_number_of_recommendations_respects_the_configured_limit
    limit = project_config.fetch("analytics", "max_recommendations").to_i

    assert_operator report["recommendations_detailed"].size, :<=, limit
  end

  # --- разделы, без которых по распределению нельзя сделать выводов --------

  def test_outcomes_add_up_to_the_number_of_operations
    outcomes = report["outcomes"]
    total = outcomes["approved"] + outcomes["rejected"] + outcomes["expired"]

    assert_equal report["total_operations"], total
    assert_in_delta outcomes["approved"].to_f / report["total_operations"], outcomes["approval_rate"], 0.001
  end

  def test_provider_performance_matches_the_attempts_in_decisions
    attempts = Hash.new(0)
    decisions.each do |decision|
      decision["cascade"]["path"].each { |step| attempts[step["provider"]] += 1 }
    end

    report["provider_performance"].each do |id, row|
      assert_equal attempts.fetch(id, 0), row["attempts"], "число попыток по #{id} расходится с хронологией каскада"
      assert_equal row["approved"] + row["declined"] + row["expired"], row["attempts"],
                   "каждая попытка по #{id} должна иметь исход"
    end
  end

  def test_cascade_statistics_match_the_recorded_paths
    depths = decisions.map { |d| d["cascade"]["path"].size }

    assert_equal depths.max, report["cascade"]["max_depth"]
    assert_equal depths.count { |d| d <= 1 }, report["cascade"]["single_attempt"]
    assert_equal depths.count { |d| d > 1 }, report["cascade"]["multi_attempt"]
    assert_in_delta depths.sum.to_f / depths.size, report["cascade"]["avg_depth"], 0.01
  end

  def test_goal_relaxations_are_carried_from_decisions_into_the_report
    relaxations = report["goal_relaxations"].select { |event| event["type"] == "goal_relaxation" }
    in_decisions = decisions.sum { |d| d["events"].count { |e| e["type"] == "goal_relaxation" } }

    assert_equal in_decisions, relaxations.size
    relaxations.each do |event|
      assert_includes event.keys, "operation_id", "уступка должна быть привязана к заявке"
      assert_includes event.keys, "unreachable"
      assert_includes event.keys, "reallocated_to"
    end
  end

  def test_data_quality_section_carries_input_remarks
    quality = report["data_quality"]

    refute_nil quality, "замечания к данным должны быть видны в отчёте"
    assert_includes quality.keys, "counts"
    refute_includes quality["counts"].keys, "error", "боевой прогон не должен давать ошибок в данных"
  end

  def test_routing_setup_documents_the_pipeline_that_produced_the_report
    setup = report["routing_setup"]

    assert_equal "balanced", setup["profile"]
    assert_equal 11, setup["hard_constraints"].size
    assert_equal 8, setup["strategies"].size
    assert_equal %w[vipay payflow quickpay spacepayments], setup["providers"]
  end

  # --- отчёт собирается и на вырожденных данных ----------------------------

  def test_report_survives_an_empty_set_of_decisions
    fleet = Routing::Ingest::Loader.new(project_config).load_fleet(RoutingTest::PROVIDERS_PATH)
    built = Routing::Analytics::Report.new(decisions: [], fleet: fleet, config: project_config,
                                           period: "2026-07-30").to_h

    assert_equal 0, built["total_operations"]
    assert_in_delta 0.0, built["outcomes"]["approval_rate"]
    assert_empty built["skip_reasons"]
    assert(built["distribution"].values.all? { |row| row["count"].zero? })
  end
end
