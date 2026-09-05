# frozen_string_literal: true

require "test_helper"

# Обстрел случайными очередями живёт в tools/fuzz.rb и запускается отдельно
# (`rake fuzz`): полторы тысячи очередей — это минуты, а не секунды. Здесь
# проверяется сама обвязка: что генератор даёт разные очереди, что проверка
# инвариантов действительно ловит нарушение, и что несколько очередей проходят.
# Без этого «фаззер зелёный» ничего не значило бы: молчать он умеет и сломанным.
class FuzzTest < Minitest::Test
  include RoutingTest

  def setup
    require_relative "../tools/fuzz"
  end

  def test_the_same_seed_gives_the_same_queue_and_different_seeds_do_not
    assert_equal ::Fuzz.build_case(7).queue, ::Fuzz.build_case(7).queue
    refute_equal ::Fuzz.build_case(7).queue, ::Fuzz.build_case(8).queue
  end

  def test_generator_covers_all_three_kinds
    kinds = (1..60).map { |seed| ::Fuzz.build_case(seed).kind }.uniq

    assert_equal %i[plausible edgy hostile].sort, kinds.sort
  end

  def test_a_handful_of_generated_queues_survive_the_pipeline
    Dir.mktmpdir("fuzz-test-") do |dir|
      (1..4).each do |seed|
        kase = ::Fuzz.build_case(seed)

        assert_empty ::Fuzz.check(kase, dir), "очередь seed=#{seed} (#{kase.kind}) нарушила инварианты"
      end
    end
  end

  # Проверка инвариантов обязана уметь падать, иначе зелёный обстрел ничего
  # не доказывает: подсовываем результат, где у заявки нет провайдера.
  def test_invariants_catch_a_broken_result
    problems = ::Fuzz.invariants(operations: [:one, :two], decisions: [], dump: "[]", report: {})

    refute_empty problems
  end
end
