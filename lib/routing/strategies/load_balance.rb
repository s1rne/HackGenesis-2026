# frozen_string_literal: true

module Routing
  module Strategies
    # Стратегия 6: учёт текущей загрузки.
    #
    # Загрузка уже проверяется жёсткими ограничениями, но там вопрос бинарный:
    # лимит достигнут или нет. Здесь она влияет на предпочтение: провайдер,
    # выбравший 95% дневного лимита, формально ещё доступен, но отдавать ему
    # заявку, когда рядом есть свободный, — способ упереться в потолок раньше
    # времени и потерять весь оставшийся день.
    #
    # Загрузка берётся как максимум по всем измерениям — дневной оборот,
    # заявки в работе, реквизиты, интенсивность: узкое место определяет
    # именно самый нагруженный лимит.
    class LoadBalance < Base
      def raw_score(context)
        1.0 - context.state.load_factor(context.at)
      end

      def explain(context)
        state = context.state
        parts = {
          "дневной оборот" => state.daily_utilization,
          "заявки в работе" => state.in_progress_count_utilization,
          "сумма в работе" => state.in_progress_amount_utilization,
          "реквизиты" => state.requisite_utilization,
          "интенсивность" => state.rate_utilization(context.at)
        }.reject { |_, value| value.nil? || value.zero? }

        return "загрузка нулевая по всем лимитам" if parts.empty?

        top = parts.max_by { |_, value| value }
        "загрузка #{pct(state.load_factor(context.at))}%, узкое место — #{top.first} (#{pct(top.last)}%)"
      end
    end
  end
end
