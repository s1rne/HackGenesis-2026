# frozen_string_literal: true

require_relative "test_helper"

# Разбор одной заявки.
#
# В проде это самый частый вопрос к роутеру, и задаёт его обычно не
# разработчик: «почему эта выплата ушла именно туда». Ответ должен читаться
# без чтения кода, поэтому проверяется не структура, а то, что в выводе есть
# все части ответа — и что команда не врёт, когда её просят разобрать
# несуществующую заявку.
class ExplainTest < Minitest::Test
  include RoutingTest

  def test_explains_a_choice_between_several_providers
    output = explain("op_101")

    assert_includes output, "Заявка op_101"
    assert_includes output, "Кого рассматривали:"
    assert_includes output, "Почему выбран именно он:"
    assert_includes output, "Разбор скоринга победителя"
    assert_includes output, "Сравнивали с:", "нужно видеть, с кем шло сравнение"
  end

  def test_every_considered_provider_appears_with_a_human_reason
    output = explain("op_103")

    %w[vipay payflow quickpay].each do |provider|
      assert_includes output, provider, "провайдер #{provider} должен быть в разборе"
    end
    assert_includes output, "сумма больше максимального чека провайдера",
                    "код причины обязан сопровождаться человеческой формулировкой"
  end

  # При единственном допустимом провайдере все факторы нормализуются
  # в нейтральные значения. Печатать такую таблицу — создавать видимость
  # выбора, которого не было.
  def test_no_scoring_breakdown_when_there_was_no_choice
    refute_includes explain("op_103"), "Разбор скоринга победителя"
  end

  def test_cascade_history_is_shown_when_there_were_retries
    output = explain("op_103")

    assert_includes output, "Хронология попыток:"
    assert_match(/Всего попыток: [2-9]/, output)
  end

  def test_unknown_operation_is_refused_with_a_hint
    result = run_explain("op_does_not_exist")

    refute_equal 0, result[:status].exitstatus
    assert_match(/нет заявки op_does_not_exist/, result[:output])
  end

  def test_missing_operation_id_is_refused
    result = run_explain(nil)

    refute_equal 0, result[:status].exitstatus
    assert_match(/Укажите операцию/, result[:output])
  end

  private

  def explain(id)
    result = run_explain(id)
    assert_equal 0, result[:status].exitstatus, "разбор #{id} завершился с ошибкой:\n#{result[:output]}"
    result[:output]
  end

  def run_explain(id)
    args = [RoutingTest::RUBY, "bin/route", "explain",
            "--decisions", RoutingTest.pipeline[:decisions_path]]
    args << id if id

    output = nil
    status = nil
    Dir.chdir(RoutingTest::PROJECT_ROOT) do
      read, write = IO.pipe
      pid = Process.spawn(*args, out: write, err: write)
      write.close
      output = read.read
      _, status = Process.wait2(pid)
      read.close
    end
    { output: output, status: status }
  end
end
