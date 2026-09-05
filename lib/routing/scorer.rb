# frozen_string_literal: true

module Routing
  # Согласование целей: как выбрать одного, когда цели указывают на разных.
  #
  # Просто сложить веса недостаточно. Доля трафика и обязательство по обороту —
  # цели разной природы: первая описывает, как хотелось бы, вторая — что мы
  # обязаны партнёру. Поэтому цели разложены по эшелонам (tier), и старший
  # эшелон решает раньше младшего.
  #
  # Работает это так:
  #   1. каждая цель даёт сырую величину в своих единицах;
  #   2. величины нормализуются по пулу кандидатов в 0..1 — теперь их можно складывать;
  #   3. внутри эшелона считается взвешенная сумма;
  #   4. эшелоны сравниваются по очереди; если разрыв в старшем меньше
  #      tier_epsilon, кандидаты считаются равными и спор уходит вниз;
  #   5. остаток ничьих разводит явная цепочка tie_break — чтобы результат
  #      был воспроизводимым, а не зависел от порядка ключей в JSON.
  #
  # Настройки mode, tier, weight, tier_epsilon и tie_break живут в конфигурации:
  # порядок разрешения конфликтов меняется без единой правки кода.
  class Scorer
    Contribution = Struct.new(:strategy, :raw, :normalized, :weight, :tier, :contribution, :explanation,
                              keyword_init: true) do
      # Ключи строковые: этот хеш кладётся внутрь записи попытки, где все ключи
      # строковые, и смешивать символы со строками в одной структуре — способ
      # получить незаметную ошибку. В JSON разница не видна, в коде — видна сразу.
      def to_h
        {
          "factor" => strategy,
          "tier" => tier,
          "weight" => weight.round(3),
          "raw" => raw.nil? ? nil : raw.round(4),
          "normalized" => normalized.round(4),
          "contribution" => contribution.round(4),
          "note" => explanation
        }.compact
      end
    end

    Ranked = Struct.new(:context, :total, :tier_scores, :contributions, keyword_init: true) do
      def provider_id = context.provider.id

      def contribution_for(strategy_id) = contributions.find { |c| c.strategy == strategy_id }

      def to_h
        {
          "provider" => provider_id,
          "score" => total.round(4),
          "tiers" => tier_scores.transform_keys(&:to_s).transform_values { |value| value.round(4) },
          "factors" => contributions.map(&:to_h)
        }
      end
    end

    attr_reader :strategies, :config

    def initialize(strategies, config)
      @strategies = strategies
      @config = config
      @mode = config.fetch("scoring", "mode", default: "lexicographic_weighted").to_s
      @epsilon = config.fetch("scoring", "tier_epsilon", default: 0.05).to_f
      @tie_break = Array(config.fetch("scoring", "tie_break", default: %w[provider_id]))
    end

    # Принимает список EvaluationContext (уже прошедших жёсткие ограничения)
    # и возвращает их же, отранжированными от лучшего к худшему.
    def rank(contexts)
      return [] if contexts.empty?

      matrix = build_matrix(contexts)
      ranked = contexts.each_with_index.map do |context, index|
        contributions = matrix.map { |row| row[index] }
        Ranked.new(
          context: context,
          total: weighted_total(contributions),
          tier_scores: tier_scores(contributions),
          contributions: contributions
        )
      end

      order(ranked)
    end

    # Какая именно цель решила спор между победителем и следующим за ним.
    # Берём не самый большой вклад, а самый большой ОТРЫВ: цель, по которой
    # оба кандидата одинаково хороши, ничего не объясняет.
    def decisive_factor(ranked_list)
      return nil if ranked_list.size < 2

      winner, runner_up = ranked_list
      gaps = winner.contributions.filter_map do |contribution|
        rival = runner_up.contribution_for(contribution.strategy)
        next if rival.nil?

        gap = contribution.contribution - rival.contribution
        [contribution, gap] if gap > 1e-9
      end
      return nil if gaps.empty?

      gaps.max_by { |_, gap| gap }.first
    end

    private

    # Матрица «цель x кандидат» с уже нормализованными значениями.
    def build_matrix(contexts)
      strategies.map do |strategy|
        raws = contexts.map do |context|
          begin
            strategy.raw_score(context)
          rescue StandardError => e
            raise RuleError.new(e.message, rule: strategy.id)
          end
        end

        # Цель с собственной шкалой 0..1 берётся как есть: растягивать её
        # по кандидатам значило бы стирать величину разницы, ради которой
        # она и считается.
        normalized = strategy.absolute? ? raws.map { |raw| raw&.clamp(0.0, 1.0) } : Statistics.min_max_normalize(raws)
        contexts.each_with_index.map do |context, index|
          value = normalized[index] || 0.5
          Contribution.new(
            strategy: strategy.id,
            raw: raws[index],
            normalized: value,
            weight: strategy.weight,
            tier: strategy.tier,
            contribution: value * strategy.weight,
            explanation: safe_explain(strategy, context)
          )
        end
      end
    end

    def safe_explain(strategy, context)
      strategy.explain(context)
    rescue StandardError
      nil
    end

    def weighted_total(contributions)
      total_weight = contributions.sum(&:weight)
      return 0.0 if total_weight.zero?

      contributions.sum(&:contribution) / total_weight
    end

    def tier_scores(contributions)
      contributions.group_by(&:tier).transform_values do |group|
        weight = group.sum(&:weight)
        weight.zero? ? 0.0 : group.sum(&:contribution) / weight
      end
    end

    def order(ranked)
      case @mode
      when "weighted"
        ranked.sort { |a, b| compare_totals(a, b) }
      when "lexicographic", "lexicographic_weighted"
        tiers = ranked.flat_map { |r| r.tier_scores.keys }.uniq.sort
        rank_by_tiers(ranked, tiers)
      else
        raise ConfigError, "неизвестный режим скоринга: #{@mode}"
      end
    end

    # Эшелоны сравниваются по очереди. Кандидаты, отставшие от лидера эшелона
    # меньше чем на tier_epsilon, считаются равными в нём — спор между ними
    # уходит в следующий эшелон. Так «почти равная» конверсия не перебивает
    # долю трафика из-за третьего знака после запятой.
    def rank_by_tiers(ranked, tiers)
      return tie_break_sort(ranked) if ranked.size <= 1 || tiers.empty?

      tier = tiers.first
      rest = tiers[1..]
      sorted = ranked.sort_by { |r| [-(r.tier_scores[tier] || 0.0), r.provider_id] }

      clusters = []
      sorted.each do |candidate|
        leader = clusters.last&.first
        if leader && ((leader.tier_scores[tier] || 0.0) - (candidate.tier_scores[tier] || 0.0)).abs <= @epsilon
          clusters.last << candidate
        else
          clusters << [candidate]
        end
      end

      clusters.flat_map { |cluster| cluster.size == 1 ? cluster : rank_by_tiers(cluster, rest) }
    end

    def compare_totals(left, right)
      by_total = right.total <=> left.total
      by_total.zero? ? tie_break_compare(left, right) : by_total
    end

    def tie_break_sort(ranked)
      return ranked if ranked.size <= 1

      ranked.sort do |a, b|
        by_total = b.total <=> a.total
        by_total.abs < 1e-9 ? tie_break_compare(a, b) : by_total
      end
    end

    # Явная, описанная в конфигурации цепочка разрешения ничьих.
    # Последним всегда идёт идентификатор — он гарантирует, что порядок
    # определён полностью и результат воспроизводим от прогона к прогону.
    def tie_break_compare(left, right)
      @tie_break.each do |key|
        result = compare_by(key.to_s, left, right)
        return result unless result.zero?
      end
      left.provider_id <=> right.provider_id
    end

    def compare_by(key, left, right)
      case key
      when "provider_id"
        left.provider_id <=> right.provider_id
      when "cascade_priority"
        (left.context.provider.priority || Float::INFINITY) <=> (right.context.provider.priority || Float::INFINITY)
      when "conversion"
        (right.context.provider.conversion_24h || 0.0) <=> (left.context.provider.conversion_24h || 0.0)
      when "load"
        left.context.state.load_factor(left.context.at) <=> right.context.state.load_factor(right.context.at)
      when "margin"
        (right.context.provider.margin_gap || -Float::INFINITY) <=> (left.context.provider.margin_gap || -Float::INFINITY)
      else
        contribution = [left.contribution_for(key), right.contribution_for(key)]
        return 0 if contribution.any?(&:nil?)

        contribution[1].contribution <=> contribution[0].contribution
      end
    end
  end
end
