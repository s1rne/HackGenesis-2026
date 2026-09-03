# frozen_string_literal: true

module Routing
  module Strategies
    # Здоровье провайдера: реакция на серию отказов подряд.
    #
    # Конверсия отвечает на вопрос «как этот партнёр работает вообще».
    # Здоровье — на другой: «работает ли он прямо сейчас». Это разные вещи,
    # и путать их дорого. Провайдер с исторической конверсией 0.87, у которого
    # десять минут назад отвалился шлюз, по конверсии всё ещё выглядит лучшим.
    #
    # Считать это конверсией нельзя по арифметике: при двадцати виртуальных
    # наблюдениях два отказа подряд роняют оценку примерно на восемь пунктов —
    # провайдер, легший в полдень, успеет получить ещё десяток выплат, прежде
    # чем статистика его догонит.
    #
    # Поэтому серия отказов — отдельная цель в старшем эшелоне. Пока у всех
    # ноль отказов подряд, она возвращает всем одно и то же, эшелон остаётся
    # ничейным и решение честно уходит вниз, к долям и конверсии. Как только
    # кто-то начинает падать, он проваливается в самый низ очереди — но не
    # исключается: если он единственный допустимый, заявка всё равно уйдёт ему.
    # Именно поэтому это цель, а не жёсткое ограничение: аварийный выключатель
    # не должен уметь отрезать последний оставшийся маршрут.
    class ProviderHealth < Base
      def raw_score(context)
        context.state.health(context.at, threshold: threshold, recovery_sec: recovery_sec)
      end

      def explain(context)
        state = context.state
        failures = state.consecutive_failures
        return "отказов подряд нет, здоровье полное" if failures.zero?

        value = raw_score(context)
        elapsed = elapsed_since_failure(context)
        base = "#{failures} #{plural(failures, 'отказ', 'отказа', 'отказов')} подряд"
        return "#{base}, здоровье #{pct(value)}%" if elapsed.nil?

        "#{base}, последний #{elapsed.round} с назад — здоровье #{pct(value)}%, " \
          "восстановится за #{recovery_sec.round} с"
      end

      private

      def elapsed_since_failure(context)
        at = context.at
        last = context.state.last_failure_at
        return nil if at.nil? || last.nil? || !at.to_f.finite?

        at.to_f - last.to_f
      end

      # Сколько отказов подряд считать полной потерей здоровья.
      def threshold = setting("failures_to_zero", 2).to_f

      # За сколько секунд здоровье восстанавливается полностью.
      def recovery_sec = setting("recovery_sec", 300).to_f

      def plural(count, one, few, many)
        tail = count.abs % 100
        return many if (11..14).cover?(tail)

        case tail % 10
        when 1 then one
        when 2, 3, 4 then few
        else many
        end
      end
    end
  end
end
