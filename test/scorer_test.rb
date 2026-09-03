# frozen_string_literal: true

require_relative "test_helper"

# Согласование целей: что происходит, когда цели указывают на разных провайдеров.
#
# Цели подставляются заглушками, а не боевыми классами. Так проверяется именно
# механизм согласования — эшелоны, эпсилон, тай-брейк, — а не то, какое число
# сегодня вернула конверсия.
class ScorerTest < Minitest::Test
  Stub = RoutingTest::StubStrategy

  def setup
    @providers = [
      build_provider({ "payment_system" => "alpha", "status" => "active", "traffic_percentage" => 34,
                       "priority" => 3, "conversion_24h" => 0.70, "provider_margin_pct" => 1.0,
                       "merchant_margin_pct" => 1.5 }),
      build_provider({ "payment_system" => "bravo", "status" => "active", "traffic_percentage" => 33,
                       "priority" => 1, "conversion_24h" => 0.90, "provider_margin_pct" => 1.2,
                       "merchant_margin_pct" => 1.5 }),
      build_provider({ "payment_system" => "charlie", "status" => "active", "traffic_percentage" => 33,
                       "priority" => 2, "conversion_24h" => 0.50, "provider_margin_pct" => 0.8,
                       "merchant_margin_pct" => 1.5 })
    ]
    @fleet = build_fleet(@providers)
    @operation = build_operation(amount: 10_000)
  end

  def contexts(ids = %w[alpha bravo charlie])
    ids.map do |id|
      provider = @providers.find { |p| p.id == id }
      context_for(provider: provider, operation: @operation, fleet: @fleet, at: 1000.0, eligible_ids: ids)
    end
  end

  def scorer(strategies, overrides = {})
    Routing::Scorer.new(strategies, overrides.empty? ? project_config : config_with(overrides))
  end

  def order(strategies, overrides = {}, ids: %w[alpha bravo charlie])
    scorer(strategies, overrides).rank(contexts(ids)).map(&:provider_id)
  end

  # --- (а) конфликт эшелонов ------------------------------------------------

  def test_senior_tier_wins_when_tiers_point_at_different_providers
    senior = Stub.new("commitment", tier: 1, weight: 1.0, scores: { "alpha" => 10.0, "bravo" => 0.0, "charlie" => 0.0 })
    junior = Stub.new("share", tier: 2, weight: 5.0, scores: { "alpha" => 0.0, "bravo" => 10.0, "charlie" => 5.0 })

    assert_equal "alpha", order([senior, junior], {}, ids: %w[alpha bravo charlie]).first,
                 "младший эшелон не перебивает старший даже впятеро большим весом"
  end

  def test_junior_tier_decides_only_inside_a_senior_tier_draw
    senior = Stub.new("commitment", tier: 1, weight: 1.0, scores: { "alpha" => 1.0, "bravo" => 1.0, "charlie" => 0.0 })
    junior = Stub.new("share", tier: 2, weight: 1.0, scores: { "alpha" => 0.0, "bravo" => 1.0, "charlie" => 9.0 })

    ranked = order([senior, junior])

    assert_equal "bravo", ranked.first, "среди равных в старшем эшелоне выбирает младший"
    assert_equal "charlie", ranked.last, "проигравший старший эшелон не спасается младшим"
  end

  def test_weights_matter_inside_a_tier
    left = Stub.new("count_share", tier: 2, weight: 2.0, scores: { "alpha" => 1.0, "bravo" => 0.0, "charlie" => 0.0 })
    right = Stub.new("conversion", tier: 2, weight: 0.5, scores: { "alpha" => 0.0, "bravo" => 1.0, "charlie" => 0.0 })

    assert_equal "alpha", order([left, right]).first
    heavier = Stub.new("conversion", tier: 2, weight: 5.0, scores: { "alpha" => 0.0, "bravo" => 1.0, "charlie" => 0.0 })

    assert_equal "bravo", order([left, heavier]).first,
                 "внутри эшелона решает взвешенная сумма, а веса живут в конфигурации"
  end

  # --- (б) эпсилон эшелона --------------------------------------------------

  def test_gap_smaller_than_tier_epsilon_moves_the_argument_to_the_junior_tier
    # После нормализации alpha=1.00, bravo=0.99, charlie=0.00.
    senior = Stub.new("commitment", tier: 1, weight: 1.0,
                      scores: { "alpha" => 1.0, "bravo" => 0.99, "charlie" => 0.0 })
    junior = Stub.new("share", tier: 2, weight: 1.0,
                      scores: { "alpha" => 0.0, "bravo" => 1.0, "charlie" => 1.0 })

    assert_equal "bravo", order([senior, junior], { "scoring" => { "tier_epsilon" => 0.05 } }).first,
                 "разрыв 0.01 меньше эпсилона: кандидаты равны в старшем эшелоне"
  end

  def test_gap_larger_than_tier_epsilon_is_decided_in_place
    senior = Stub.new("commitment", tier: 1, weight: 1.0,
                      scores: { "alpha" => 1.0, "bravo" => 0.99, "charlie" => 0.0 })
    junior = Stub.new("share", tier: 2, weight: 1.0,
                      scores: { "alpha" => 0.0, "bravo" => 1.0, "charlie" => 1.0 })

    assert_equal "alpha", order([senior, junior], { "scoring" => { "tier_epsilon" => 0.0 } }).first,
                 "при нулевом эпсилоне спор не уходит вниз и решается третьим знаком"
  end

  def test_tier_epsilon_never_lets_a_distant_candidate_into_the_cluster
    senior = Stub.new("commitment", tier: 1, weight: 1.0,
                      scores: { "alpha" => 1.0, "bravo" => 0.99, "charlie" => 0.0 })
    junior = Stub.new("share", tier: 2, weight: 1.0,
                      scores: { "alpha" => 0.0, "bravo" => 0.0, "charlie" => 10.0 })

    assert_equal "charlie", order([senior, junior], { "scoring" => { "tier_epsilon" => 0.05 } }).last,
                 "charlie отстал в старшем эшелоне сильнее эпсилона и наверх не поднимется"
  end

  # --- (в) цепочка тай-брейка -----------------------------------------------

  def test_full_draw_is_resolved_by_the_configured_tie_break_chain
    flat = Stub.new("flat", tier: 1, weight: 1.0, scores: { "alpha" => 5.0, "bravo" => 5.0, "charlie" => 5.0 })

    by_priority = order([flat], { "scoring" => { "tie_break" => %w[cascade_priority provider_id] } })

    assert_equal %w[bravo charlie alpha], by_priority,
                 "первый ключ цепочки — приоритет в каскаде: 1, 2, 3"
  end

  def test_tie_break_chain_is_configurable_without_touching_the_code
    flat = Stub.new("flat", tier: 1, weight: 1.0, scores: { "alpha" => 5.0, "bravo" => 5.0, "charlie" => 5.0 })

    assert_equal %w[bravo alpha charlie],
                 order([flat], { "scoring" => { "tie_break" => %w[conversion provider_id] } }),
                 "по конверсии: 0.90, 0.70, 0.50"
    assert_equal %w[charlie alpha bravo],
                 order([flat], { "scoring" => { "tie_break" => %w[margin provider_id] } }),
                 "по остатку маржи мерчанту: charlie 0.7, alpha 0.5, bravo 0.3 п.п."
    assert_equal %w[alpha bravo charlie],
                 order([flat], { "scoring" => { "tie_break" => %w[provider_id] } }),
                 "по идентификатору — алфавит"
  end

  def test_tie_break_always_ends_with_a_total_order
    flat = Stub.new("flat", tier: 1, weight: 1.0, scores: { "alpha" => 5.0, "bravo" => 5.0, "charlie" => 5.0 })
    # Цепочка, которая ничего не различает: идентификатор дописывается сам.
    ranked = order([flat], { "scoring" => { "tie_break" => [] } })

    assert_equal %w[alpha bravo charlie], ranked
  end

  def test_full_draw_is_reproducible_across_runs
    flat = Stub.new("flat", tier: 1, weight: 1.0, scores: { "alpha" => 5.0, "bravo" => 5.0, "charlie" => 5.0 })
    first = order([flat], {}, ids: %w[alpha bravo charlie])
    second = order([flat], {}, ids: %w[charlie bravo alpha])

    assert_equal first, second, "порядок кандидатов на входе не должен влиять на результат"
  end

  # --- (г) решающий фактор --------------------------------------------------

  def test_decisive_factor_is_the_largest_gap_not_the_largest_contribution
    # flat даёт победителю самый большой вклад (0.9), но соперник получает
    # ровно столько же — этот фактор ничего не объясняет.
    flat = Stub.new("flat", tier: 1, weight: 1.8, scores: { "alpha" => 1.0, "bravo" => 1.0, "charlie" => 1.0 })
    sharp = Stub.new("sharp", tier: 1, weight: 0.3, scores: { "alpha" => 1.0, "bravo" => 0.0, "charlie" => 0.0 })

    engine = scorer([flat, sharp])
    ranked = engine.rank(contexts)
    winner = ranked.first

    assert_equal "alpha", winner.provider_id
    assert_equal "flat", winner.contributions.max_by(&:contribution).strategy,
                 "самый большой вклад у flat"
    assert_equal "sharp", engine.decisive_factor(ranked).strategy,
                 "но решил спор sharp — только по нему кандидаты и различаются"
  end

  def test_decisive_factor_is_nil_when_nothing_separates_the_leaders
    flat = Stub.new("flat", tier: 1, weight: 1.0, scores: { "alpha" => 5.0, "bravo" => 5.0, "charlie" => 5.0 })
    engine = scorer([flat])

    assert_nil engine.decisive_factor(engine.rank(contexts))
  end

  def test_decisive_factor_needs_at_least_two_candidates
    flat = Stub.new("flat", tier: 1, weight: 1.0, scores: { "alpha" => 5.0 })
    engine = scorer([flat])

    assert_nil engine.decisive_factor(engine.rank(contexts(%w[alpha])))
  end

  # --- прозрачность и устойчивость -----------------------------------------

  def test_ranking_exposes_every_factor_for_explanation
    strategies = [Stub.new("count_share", tier: 2, weight: 1.0, scores: { "alpha" => 1.0, "bravo" => 0.5, "charlie" => 0.0 }),
                  Stub.new("conversion", tier: 2, weight: 1.0, scores: { "alpha" => 0.0, "bravo" => 1.0, "charlie" => 0.5 })]
    row = scorer(strategies).rank(contexts).first.to_h

    # Ключи строковые: раскладка кладётся внутрь записи попытки, где все
    # ключи строковые, и смешивать символы со строками в одной структуре нельзя.
    assert_equal %w[provider score tiers factors], row.keys
    assert_equal %w[count_share conversion], row["factors"].map { |f| f["factor"] }
    row["factors"].each do |factor|
      assert_includes factor.keys, "normalized"
      assert_includes factor.keys, "contribution"
      assert_includes factor.keys, "note", "у фактора должно быть человеческое пояснение"
    end
  end

  def test_goal_that_is_not_applicable_gets_a_neutral_score_instead_of_zero
    # nil означает «цель неприменима», а не «худший результат».
    partial = Stub.new("partial", tier: 2, weight: 1.0, scores: { "alpha" => nil, "bravo" => nil, "charlie" => nil })
    ranked = scorer([partial]).rank(contexts)

    assert(ranked.all? { |r| r.contributions.first.normalized == 0.5 })
  end

  def test_a_goal_that_raises_is_reported_as_a_rule_error_with_its_name
    broken = Class.new do
      def id = "broken_goal"
      def weight = 1.0
      def tier = 1
      def raw_score(_context) = raise("деление на ноль")
      def explain(_context) = nil
    end.new

    error = assert_raises(Routing::RuleError) { scorer([broken]).rank(contexts) }

    assert_equal "broken_goal", error.rule
    assert_match(/broken_goal/, error.message)
  end

  def test_unknown_scoring_mode_is_a_configuration_error
    flat = Stub.new("flat", tier: 1, weight: 1.0, scores: { "alpha" => 1.0, "bravo" => 1.0, "charlie" => 1.0 })
    error = assert_raises(Routing::ConfigError) do
      scorer([flat], { "scoring" => { "mode" => "по звёздам" } }).rank(contexts)
    end

    assert_match(/по звёздам/, error.message)
  end

  def test_weighted_mode_collapses_tiers_into_one_sum
    senior = Stub.new("commitment", tier: 1, weight: 1.0, scores: { "alpha" => 1.0, "bravo" => 0.0, "charlie" => 0.0 })
    junior = Stub.new("share", tier: 2, weight: 5.0, scores: { "alpha" => 0.0, "bravo" => 1.0, "charlie" => 0.0 })

    assert_equal "alpha", order([senior, junior], { "scoring" => { "mode" => "lexicographic_weighted" } }).first
    assert_equal "bravo", order([senior, junior], { "scoring" => { "mode" => "weighted" } }).first,
                 "в режиме weighted эшелоны не разделяются и больший вес перевешивает"
  end

  def test_ranking_an_empty_pool_returns_nothing
    assert_empty scorer([Stub.new("flat", tier: 1, weight: 1.0, scores: {})]).rank([])
  end
end
