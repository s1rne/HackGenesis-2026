# frozen_string_literal: true

module Routing
  # Каскад: превращает одну заявку в одно решение.
  #
  # Порядок шагов зафиксирован и не зависит от выбранной стратегии:
  #   1. жёсткие ограничения отсеивают недопустимых — каждого с причиной;
  #   2. если чья-то целевая доля оказалась недостижимой, она перераспределяется
  #      между доступными, и уступка записывается в решение;
  #   3. оставшиеся ранжируются скорингом активных целей;
  #   4. лучший получает заявку; при отказе в приёме каскад идёт к следующему;
  #   5. когда допустимых не осталось — политика исчерпания пула.
  #
  # Массив attempts собирается в порядке провайдеров из входного файла — так же,
  # как в образце организаторов, — а настоящая хронология каскада не теряется:
  # у каждой попытки есть поле sequence, а весь путь целиком лежит в cascade.path.
  class Cascade
    def initialize(fleet:, constraints:, scorer:, simulator:, config:, clock: nil, calibration: nil)
      @fleet = fleet
      @constraints = constraints
      @scorer = scorer
      @simulator = simulator
      @config = config
      @clock = clock || Clock.new
      @calibration = calibration
      @max_attempts = config.fetch("run", "max_attempts", default: 3).to_i.clamp(1, 50)
      @exhausted_policy = config.fetch("run", "exhausted_pool_policy", default: "retry_best").to_s
      @profile = config.fetch("profile")
      # Пересчитывать ли цели по долям на доступное подмножество провайдеров.
      # Выключено — цели считаются по всему пулу, и недоступный провайдер
      # тянет распределение на себя, оставаясь недостижимым. Включено —
      # его доля честно расходится по тем, кто может принять заявку.
      @reallocate = config.fetch("goal_relaxation", "reallocate_unreachable_share", default: true)
    end

    def route(operation)
      at = @clock.advance_to(operation)
      records = []
      events = []
      path = []
      @sequence = 0

      eligible = hard_filter(operation, at, records)
      events.concat(relaxation_events(eligible))

      outcome = if eligible.empty?
                  use_fallback(operation, at, records, path, events)
                else
                  run_cascade(operation, at, eligible, records, path, events)
                end

      # Доля трафика считается по итоговому выбору, поэтому отмечаем его один раз
      # и только здесь: попытки, закончившиеся отказом, в долю не входят.
      @fleet[outcome[:selected]].record_selection(operation) if outcome[:selected]

      mark_untouched(eligible, records, outcome[:selected])
      build_decision(operation, outcome, records, events, path)
    end

    private

    # --- шаг 1: допуск -------------------------------------------------------

    def hard_filter(operation, at, records)
      @fleet.routable.each_with_object([]) do |provider, eligible|
        context = context_for(provider, operation, at)
        violation = first_violation(context)
        if violation
          @fleet[provider.id].record_skip
          records << skip_record(provider, violation, stage: "hard_filter")
        else
          eligible << provider
        end
      end
    end

    def first_violation(context)
      @constraints.each do |constraint|
        violation = begin
          constraint.check(context)
        rescue StandardError => e
          raise RuleError.new(e.message, rule: constraint.id)
        end
        return violation if violation
      end
      nil
    end

    # --- шаг 2: недостижимые цели -------------------------------------------

    # Если провайдер, которому причитается доля трафика, сейчас недоступен,
    # цель по нему выполнить нечем. Мы не делаем вид, что её не было:
    # доля перераспределяется между доступными, а факт уступки уезжает
    # в решение и потом в отчёт.
    def relaxation_events(eligible)
      return [] unless @config.fetch("goal_relaxation", "enabled", default: true)

      ids = eligible.map(&:id)
      unreachable = @fleet.unreachable_targets(ids)
      return [] if unreachable.empty?

      released = unreachable.values.sum
      [{
        "type" => "goal_relaxation",
        "goal" => "traffic_share",
        "unreachable" => unreachable.transform_values { |share| (share * 100).round(1) },
        "released_share_pct" => (released * 100).round(1),
        "reallocated_to" => ids,
        "note" => "целевая доля недоступных провайдеров (#{unreachable.keys.join(', ')}) " \
                  "перераспределена между #{ids.empty? ? 'никем: пул пуст' : ids.join(', ')}"
      }]
    end

    # --- шаг 3-4: ранжирование и попытки ------------------------------------

    def run_cascade(operation, at, eligible, records, path, events)
      remaining = eligible.dup
      refused = []
      attempt_no = 0
      last_ranking = []

      while attempt_no < @max_attempts && !remaining.empty?
        attempt_no += 1
        ranked = rank(remaining, operation, at, attempt_no)
        last_ranking = ranked
        best = ranked.first
        provider = best.context.provider
        response = attempt(operation, provider, at, attempt_no)
        path << { "provider" => provider.id, "attempt" => attempt_no, "outcome" => response.outcome.to_s,
                  "latency_sec" => response.latency_sec }

        unless response.refused?
          records << selection_record(best, ranked, response, attempt_no, eligible.size)
          return { selected: provider.id, response: response, ranking: ranked,
                   reason_pair: selection_reason(best, ranked, eligible.size, attempt_no),
                   latency: path.sum { |step| step["latency_sec"] } }
        end

        remaining.delete(provider)
        records << declined_record(provider, response, attempt_no, has_next: !remaining.empty?)
        refused << provider
      end

      exhausted(operation, at, eligible, refused, records, path, events, last_ranking, attempt_no)
    end

    def rank(providers, operation, at, attempt_no)
      ids = @reallocate ? providers.map(&:id) : nil
      contexts = providers.map { |provider| context_for(provider, operation, at, ids, attempt_no) }
      @scorer.rank(contexts)
    end

    def attempt(operation, provider, at, attempt_no)
      state = @fleet[provider.id]
      state.reserve(operation, at: at)
      response = @simulator.respond(operation: operation, provider: provider, state: state, attempt_no: attempt_no)
      if response.approved?
        state.settle_approved(operation)
      else
        state.settle_failed(operation, response.outcome)
      end
      response
    end

    # --- шаг 5: пул исчерпан -------------------------------------------------

    # Все допустимые провайдеры отказали. Уходить на self-провайдера в этом
    # случае — значит прятать проблему: маршрут был, отказ произошёл по
    # конверсии, а не по отсутствию маршрута, и аналитика по конверсии
    # внешних партнёров после такой подмены перестанет что-либо значить.
    # Поэтому по умолчанию мы повторяем попытку на лучшем из них.
    # Уход на fallback остаётся доступен через конфигурацию.
    def exhausted(operation, at, eligible, refused, records, path, events, ranking, attempt_no)
      events << {
        "type" => "pool_exhausted",
        "policy" => @exhausted_policy,
        "refused" => refused.map(&:id),
        "note" => "все допустимые провайдеры отказали в приёме"
      }

      if @exhausted_policy == "fallback" || refused.empty?
        return use_fallback(operation, at, records, path, events)
      end

      ranked = rank(eligible, operation, at, attempt_no + 1)
      best = ranked.first
      provider = best.context.provider
      response = attempt(operation, provider, at, attempt_no + 1)
      path << { "provider" => provider.id, "attempt" => attempt_no + 1, "outcome" => response.outcome.to_s,
                "latency_sec" => response.latency_sec, "final" => true }

      retried_same = refused.map(&:id).include?(provider.id)
      records << selection_record(
        best, ranked, response, attempt_no + 1, eligible.size,
        reason: "cascade_retry",
        details: if retried_same
                   "других допустимых провайдеров не осталось, повторная попытка на том же: " \
                   "уход на self-провайдера здесь означал бы, что маршрута не было, а он был"
                 else
                   "остальные допустимые отказали (#{refused.map(&:id).join(', ')}), " \
                   "заявка ушла лучшему из оставшихся"
                 end
      )
      { selected: provider.id, response: response, ranking: ranked,
        reason_pair: ["cascade_retry", records.last["details"]],
        latency: path.sum { |step| step["latency_sec"] } }
    end

    def use_fallback(operation, at, records, path, events)
      provider = @fleet.self_providers.find { |candidate| first_violation(context_for(candidate, operation, at)).nil? }

      if provider.nil?
        events << { "type" => "no_route", "note" => "не нашлось ни одного провайдера, включая fallback" }
        return { selected: nil, response: nil, ranking: [],
                 reason_pair: ["no_provider_available", "пул пуст и fallback недоступен"],
                 latency: path.sum { |step| step["latency_sec"] } }
      end

      attempt_no = path.size + 1
      response = attempt(operation, provider, at, attempt_no)
      path << { "provider" => provider.id, "attempt" => attempt_no, "outcome" => response.outcome.to_s,
                "latency_sec" => response.latency_sec, "fallback" => true }
      records << {
        "provider" => provider.id, "decision" => "selected", "reason" => "fallback_self_provider",
        "details" => "внешний пул пуст, заявка ушла на собственного провайдера",
        "stage" => "fallback", "sequence" => next_sequence, "attempt_no" => attempt_no,
        "outcome" => response.outcome.to_s, "latency_sec" => response.latency_sec
      }
      { selected: provider.id, response: response, ranking: [],
        reason_pair: ["fallback_self_provider", Reasons.text("fallback_self_provider")],
        latency: path.sum { |step| step["latency_sec"] } }
    end

    # --- сборка записей ------------------------------------------------------

    def context_for(provider, operation, at, eligible_ids = nil, attempt_no = 1)
      EvaluationContext.new(
        operation: operation, provider: provider, state: @fleet[provider.id], fleet: @fleet,
        at: at, config: @config, history: @calibration, attempt_no: attempt_no,
        excluded: [], eligible_ids: eligible_ids
      )
    end

    def next_sequence = (@sequence += 1)

    def skip_record(provider, violation, stage:)
      {
        "provider" => provider.id,
        "decision" => "skipped",
        "reason" => violation.reason,
        "details" => violation.details,
        "stage" => stage,
        "sequence" => next_sequence,
        "explanation" => Reasons.text(violation.reason)
      }.compact
    end

    def declined_record(provider, response, attempt_no, has_next: true)
      reason = response.outcome == :expired ? "provider_timeout" : "provider_declined"
      {
        "provider" => provider.id,
        "decision" => "skipped",
        "reason" => reason,
        "details" => "попытка #{attempt_no}: ответ #{response.outcome} за #{response.latency_sec} с, " +
                     (has_next ? "заявка передана следующему кандидату" : "других допустимых кандидатов нет"),
        "stage" => "cascade_attempt",
        "sequence" => next_sequence,
        "attempt_no" => attempt_no,
        "outcome" => response.outcome.to_s,
        "latency_sec" => response.latency_sec,
        "explanation" => Reasons.text(reason)
      }
    end

    def selection_record(best, ranked, response, attempt_no, eligible_count, reason: nil, details: nil)
      code, details = if reason
                        [reason, details || Reasons.text(reason)]
                      else
                        selection_reason(best, ranked, eligible_count, attempt_no)
                      end
      {
        "provider" => best.provider_id,
        "decision" => "selected",
        "reason" => code,
        "details" => details,
        "stage" => "cascade_attempt",
        "sequence" => next_sequence,
        "attempt_no" => attempt_no,
        "score" => best.total.round(4),
        "outcome" => response.outcome.to_s,
        "latency_sec" => response.latency_sec,
        # Раскладку скоринга показываем только там, где был выбор. При единственном
        # допустимом все факторы нормализуются в нейтральные 0.5, и таблица из
        # восьми строк создаёт видимость сравнения, которого не было.
        "factors" => eligible_count > 1 ? best.contributions.map(&:to_h) : []
      }.reject { |key, value| key == "factors" && value.empty? }
    end

    # Причина выбора — не «лучший скоринг», а конкретная цель, которая
    # решила спор с ближайшим соперником. Если соперника нет, причина
    # ровно та, что в образце организаторов: единственный допустимый.
    def selection_reason(best, ranked, eligible_count, attempt_no)
      return ["only_eligible_provider", Reasons.text("only_eligible_provider")] if eligible_count == 1
      return ["cascade_retry", Reasons.text("cascade_retry")] if attempt_no > 1 && ranked.size == 1

      decisive = @scorer.decisive_factor(ranked)
      return ["best_combined_score", Reasons.text("best_combined_score")] if decisive.nil?

      runner_up = ranked[1]&.provider_id
      code = Reasons.for_strategy(decisive.strategy)
      details = "#{decisive.explanation || Reasons.text(code)}; " \
                "решающий фактор против #{runner_up} — #{decisive.strategy}"
      [code, details]
    end

    # Допустимые провайдеры, до которых каскад не дошёл, тоже требуют
    # объяснения: иначе непонятно, рассматривались ли они вообще.
    def mark_untouched(eligible, records, selected)
      eligible.each do |provider|
        next if records.any? { |record| record["provider"] == provider.id }

        @fleet[provider.id].record_skip
        records << {
          "provider" => provider.id,
          "decision" => "skipped",
          "reason" => selected ? "not_reached_in_cascade" : "lower_score",
          "details" => selected ? "заявку принял #{selected}, стоявший выше по скорингу" : nil,
          "stage" => "ranking",
          "sequence" => next_sequence,
          "explanation" => Reasons.text(selected ? "not_reached_in_cascade" : "lower_score")
        }.compact
      end
    end

    # Порядок массива attempts — по провайдерам из входного файла, как в образце
    # организаторов. Внутри одного провайдера записи идут по времени, поэтому
    # повторная попытка после отказа видна как два шага, а не как один.
    # Настоящая хронология целиком не теряется в любом случае: у каждой записи
    # есть sequence, а путь каскада лежит отдельно в cascade.path.
    def build_decision(operation, outcome, records, events, path)
      order = @fleet.providers.each_with_index.to_h { |provider, index| [provider.id, index] }
      ordered = records.sort_by { |record| [order.fetch(record["provider"], 999), record["sequence"].to_i] }
      response = outcome[:response]

      Decision.new(
        operation: operation,
        selected_provider: outcome[:selected],
        attempts: ordered,
        simulated_result: response ? response.outcome.to_s : "rejected",
        latency_sec: outcome[:latency].to_i,
        selection_reason: outcome[:reason_pair]&.first,
        selection_details: outcome[:reason_pair]&.last,
        ranking: Array(outcome[:ranking]).map(&:to_h),
        events: events,
        cascade_path: path,
        strategy_profile: @profile
      )
    end
  end
end
