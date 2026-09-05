# frozen_string_literal: true

require_relative "test_helper"
require "routing/dashboard"

# Первый экран дашборда: надо ли вмешиваться.
#
# Тесты здесь проверяют не вёрстку, а суждение. Вердикт — единственное место
# в проекте, где решение принимается за человека: он читает заголовок и
# закрывает вкладку. Ошибиться в нём дороже, чем в любом разрезе ниже.
class DashboardVerdictTest < Minitest::Test
  include RoutingTest

  def test_clean_run_says_everything_is_fine
    assert_equal "ok", view(report: {}).verdict_level
    assert_equal "В норме", view(report: {}).verdict_headline
  end

  def test_operation_without_a_provider_is_an_error
    dashboard = view(report: {}, decisions: [{ "operation_id" => "op_1", "selected_provider" => nil }])

    assert_equal "error", dashboard.verdict_level
    assert_match(/без провайдера/, dashboard.findings.first.title)
  end

  def test_capacity_alarm_reaches_the_first_screen
    dashboard = view(report: {
                       "capacity_alarms" => {
                         "operations" => 11, "of_total" => 130, "amount_diverted" => 9900.0,
                         "by_provider" => { "payflow" => { "operations" => 11 } }
                       }
                     })
    finding = dashboard.findings.find { |item| item.title.include?("собственный гейт") }

    assert_equal "warn", dashboard.verdict_level
    refute_nil finding, "тревога об исчерпанной ёмкости обязана попадать на первый экран"
    assert_match(/payflow/, finding.detail)
    refute_empty finding.action, "у находки обязан быть адресат действия"
  end

  # Отклонение, равное доказанному минимуму, — не проблема, а лучший
  # возможный результат. Красить его в предупреждение значило бы врать.
  def test_deviation_at_the_proven_minimum_is_not_a_problem
    dashboard = view(report: at_minimum_report)
    finding = dashboard.findings.find { |item| item.severity == "ok" }

    assert_equal "ok", dashboard.verdict_level
    refute_nil finding
    assert_match(/достижимом минимуме/, finding.title)
  end

  def test_deviation_above_the_minimum_is_a_warning
    report = at_minimum_report
    report["distribution"] = { "vipay" => { "deviation_pct" => 22.0 } }
    dashboard = view(report: report)

    assert_equal "warn", dashboard.verdict_level
    assert(dashboard.findings.any? { |item| item.title.include?("Отклонение") })
  end

  # Конверсия на крошечной выборке — не новость. Если поднимать тревогу
  # по трём заявкам, их перестанут читать.
  def test_small_sample_does_not_raise_a_conversion_alarm
    quiet = view(report: conversion_report(attempts: 3))
    loud = view(report: conversion_report(attempts: 20))

    assert_equal "ok", quiet.verdict_level, "три попытки — не повод для тревоги"
    assert_equal "warn", loud.verdict_level
    assert_match(/из 20/, loud.findings.first.title)
  end

  # Русские числительные: «1 заявка», «2 заявки», «11 заявок».
  def test_counts_are_declined_properly
    { 1 => "1 заявка", 2 => "2 заявки", 5 => "5 заявок", 11 => "11 заявок", 21 => "21 заявка" }
      .each do |count, expected|
        decisions = Array.new(count) { |i| { "operation_id" => "op_#{i}", "selected_provider" => nil } }

        assert_equal expected, view(report: {}, decisions: decisions).findings.first.title[/\A[^ ]+ \S+/]
      end
  end

  private

  def at_minimum_report
    {
      "distribution" => { "vipay" => { "deviation_pct" => 5.0 } },
      "target_achievability" => { "floors" => { "rounding_pct" => 5.0, "structural_pct" => 5.0, "exact_pct" => 5.0 } }
    }
  end

  def conversion_report(attempts:)
    {
      "provider_performance" => {
        "quickpay" => { "attempts" => attempts, "observed_conversion" => 0.2, "declared_conversion" => 0.79 }
      }
    }
  end

  def view(report:, decisions: [])
    Routing::Dashboard.new(decisions: decisions, report: report,
                           options: Routing::Dashboard::DEFAULTS).view
  end
end
