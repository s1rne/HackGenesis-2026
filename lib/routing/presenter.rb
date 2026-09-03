# frozen_string_literal: true

module Routing
  # Вывод в терминал.
  #
  # Отделён от команд намеренно: команда решает, что посчитать, презентер —
  # как это показать. Пока форматирование жило внутри команд, каждая из них
  # была наполовину про маршрутизацию и наполовину про выравнивание колонок,
  # и читать её приходилось целиком, чтобы понять, что она делает.
  #
  # Здесь же собрано и молчание: флаг --quiet выключает вывод в одном месте,
  # а не в двадцати вызовах.
  class Presenter
    def initialize(quiet: false, verbose: true)
      @quiet = quiet
      @verbose = verbose
    end

    def line(text = "")
      puts(text) unless @quiet
    end

    # --- конвейер -----------------------------------------------------------

    def plan(router)
      config = router.config
      line "Профиль:            #{config.fetch('profile')}"
      line "Режим согласования: #{config.fetch('scoring', 'mode')} " \
           "(эпсилон #{config.fetch('scoring', 'tier_epsilon')})"
      line "Тай-брейк:          #{Array(config.fetch('scoring', 'tie_break')).join(' -> ')}"
      line
      line "Жёсткие ограничения (#{router.constraints.size}), в порядке проверки:"
      router.constraints.each_with_index { |constraint, index| line "  #{index + 1}. #{constraint.id}" }
      line
      line "Цели маршрутизации (#{router.strategies.size}):"
      router.strategies.group_by(&:tier).sort.each do |tier, group|
        line "  эшелон #{tier}:"
        group.sort_by(&:id).each { |goal| line format("    %-22s вес %.2f", goal.id, goal.weight) }
      end
      line
      line "Провайдеры: #{router.fleet.ids.join(', ')}"
      line "История:    #{router.calibration.size} операций"
    end

    # Факт против цели по каждому провайдеру: одна строка на провайдера,
    # отклонение со знаком — это то, на что смотрят в первую очередь.
    def distribution(decisions, router)
      total = decisions.size
      counts = decisions.group_by(&:selected_provider).transform_values(&:size)
      line
      line "Заявок: #{total}, одобрено: #{decisions.count(&:approved?)}"
      router.fleet.providers.each do |provider|
        count = counts.fetch(provider.id, 0)
        target = router.fleet.count_target(provider.id) * 100
        share = total.zero? ? 0.0 : count * 100.0 / total
        line format("  %-14s %2d  %5.1f%%  цель %5.1f%%  %+6.1f п.п.",
                    provider.id, count, share, target, share - target)
      end
    end

    # --- сравнение профилей -------------------------------------------------

    ComparisonRow = Struct.new(:profile, :counts, :approved, :latency, :diverged, keyword_init: true)

    def comparison(rows, total_operations)
      providers = rows.flat_map { |row| row.counts.keys }.compact.uniq.sort
      header = format("%-18s %6s %9s %7s  %s", "профиль", "одобр", "задержка", "иначе",
                      providers.map { |id| id[0, 9].rjust(9) }.join(" "))
      line header
      line "-" * header.length
      rows.each do |row|
        line format("%-18s %6d %9d %7s  %s", row.profile, row.approved, row.latency,
                    row.diverged.nil? ? "—" : "#{row.diverged}/#{total_operations}",
                    providers.map { |id| row.counts.fetch(id, 0).to_s.rjust(9) }.join(" "))
      end

      same = rows.select { |row| row.diverged&.zero? }.map(&:profile)
      return if same.empty?

      line
      line "Совпали с balanced на этой очереди: #{same.join(', ')}."
      line "Это свойство данных, а не настроек: порядок предпочтения, который они задают,"
      line "совпал с тем, что даёт баланс целей. На другой очереди они разойдутся."
    end

    # --- реплей -------------------------------------------------------------

    def replay(summary)
      estimate = summary["estimated_approval_rate"]
      line "Реплей истории: #{summary['operations']} операций"
      line "Совпало с историческим выбором: #{summary['agreement_with_history']} " \
           "(#{summary['agreement_pct']}%)"
      line
      line format("Одобрения по факту истории:  %.1f%%", summary["baseline_approval_rate"] * 100)
      line format("Наша политика, оценка:       %.1f%% .. %.1f%%",
                  estimate["lower"] * 100, estimate["upper"] * 100)
      line "Интервал накрывает базу: заявлять улучшение по одобрениям на этих данных нельзя."

      replay_divergence(summary["divergence"])
      replay_shares(summary["share_comparison"])
      replay_drift(summary)
    end

    # --- разбор одной заявки -------------------------------------------------

    # Ответ на вопрос, который в проде задают чаще всего: «почему эта выплата
    # ушла именно туда». Читается человеком, не разработчиком: сначала что за
    # заявка, потом кого рассматривали и почему отсеяли, потом кто выбран и по
    # какой причине, и только в конце — числа скоринга.
    def explanation(decision)
      operation = decision["operation_id"]
      line "Заявка #{operation}"
      line "  сумма #{decision['amount']} #{decision['currency'] || 'RUB'}, банк #{decision['bank'] || 'не указан'}"
      line "  итог: #{decision['selected_provider'] || 'провайдер не найден'} — " \
           "#{outcome_word(decision['simulated_result'])}, #{decision['latency_sec']} с"
      line

      line "Кого рассматривали:"
      decision["attempts"].each { |attempt| explanation_attempt(attempt) }

      explanation_choice(decision["selection"])
      explanation_cascade(decision["cascade"], decision["attempts"])
      explanation_events(decision["events"])
    end

    private

    def explanation_attempt(attempt)
      mark = attempt["decision"] == "selected" ? "-->" : "   "
      # У записи об отсеве человеческая формулировка лежит рядом, у записи
      # о выборе — нет: там причина выбора конкретна и складывается из решающего
      # фактора. Берём её из каталога, чтобы обе строки читались одинаково.
      wording = attempt["explanation"] || Routing::Reasons.text(attempt["reason"])
      line format("  %s %-14s %s", mark, attempt["provider"], wording)
      line format("      %s", attempt["details"]) if attempt["details"]
    end

    def explanation_choice(selection)
      return if selection.nil?

      line
      line "Почему выбран именно он:"
      line "  #{selection['details'] || selection['reason']}"

      candidates = Array(selection["candidates"])
      # При единственном кандидате все факторы нормализуются в нейтральные
      # значения: сравнивать не с кем. Печатать такую таблицу — создавать
      # видимость выбора, которого не было.
      return if candidates.size <= 1

      factors = Array(candidates.first["factors"])
      return if factors.empty?

      line
      line "  Сравнивали с: #{candidates.drop(1).map { |c| c['provider'] }.join(', ')}"
      line
      line "  Разбор скоринга победителя (эшелон / вес / вклад):"
      factors.sort_by { |factor| [factor["tier"], -factor["contribution"].to_f] }.each do |factor|
        line format("    эшелон %d  %-22s вес %.2f  вклад %.3f", factor["tier"], factor["factor"],
                    factor["weight"], factor["contribution"])
        line format("               %s", factor["note"]) if factor["note"]
      end
    end

    def explanation_cascade(cascade, attempts)
      steps = Array(cascade && cascade["path"])
      return if steps.size <= 1

      line
      line "Хронология попыток:"
      steps.each do |step|
        suffix = step["fallback"] ? "  (собственный провайдер)" : ""
        line format("  %d. %-14s %-9s %4d с%s", step["attempt"], step["provider"],
                    outcome_word(step["outcome"]), step["latency_sec"], suffix)
      end
      line "  Всего попыток: #{steps.size}, потрачено #{steps.sum { |step| step['latency_sec'].to_i }} с"
      _ = attempts
    end

    def explanation_events(events)
      events = Array(events)
      return if events.empty?

      line
      line "События по заявке:"
      events.each { |event| line "  #{event['type']}: #{event['note']}" }
    end

    def outcome_word(outcome)
      { "approved" => "одобрено", "rejected" => "отказ", "expired" => "истёк срок" }
        .fetch(outcome.to_s, outcome.to_s)
    end

    public

    def issues(collection)
      return if collection.nil? || collection.empty?

      counts = collection.count_by_severity
      line
      line "Замечания к данным: #{counts.map { |severity, count| "#{severity} #{count}" }.join(', ')}"
      collection.each { |issue| line "  #{issue}" } if @verbose
    end

    def problems(list)
      return if Array(list).empty?

      warn ""
      warn "Выгрузка непригодна для сдачи:"
      Array(list).each { |problem| warn "  #{problem}" }
    end

    private

    def replay_divergence(divergence)
      return if divergence.nil? || divergence["operations"].to_i.zero?

      line
      line format("Разошлись с историей на %d операциях. Там, где решение другое, средняя",
                  divergence["operations"])
      line format("конверсия выбранного нами провайдера %.1f%% против %.1f%% у исторического (%+.1f п.п.).",
                  divergence["our_provider_success_rate"] * 100,
                  divergence["historical_provider_success_rate"] * 100,
                  divergence["delta"] * 100)
    end

    def replay_shares(comparison)
      line
      line format("%-14s %8s %8s %8s", "провайдер", "цель", "история", "реплей")
      comparison.each do |id, row|
        line format("%-14s %7.1f%% %7.1f%% %7.1f%%",
                    id, row["target_pct"], row["history_pct"], row["replay_pct"])
      end
    end

    def replay_drift(summary)
      tvd = summary["total_variation_distance"]
      achievability = summary["target_achievability"]
      line
      line format("Отклонение от целей: минимум %.3f, история %.3f, мы %.3f",
                  achievability["min_total_variation_distance"],
                  tvd["history_vs_target"], tvd["replay_vs_target"])
      line achievability["verdict"]
    end
  end
end
