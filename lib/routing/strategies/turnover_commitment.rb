# frozen_string_literal: true

module Routing
  module Strategies
    # Стратегия 7: финансовые обязательства по обороту.
    #
    # Гейт нередко выдан на условии «не менее X ₽ в сутки». Невыполнение —
    # не перекос статистики, а нарушение договорённости с партнёром, поэтому
    # цель по умолчанию стоит в старшем эшелоне и способна перебить и долю
    # трафика, и конверсию.
    #
    # Но старший эшелон — сильное оружие, и включать его надо не всегда.
    # Обязательство даётся на сутки: в девять утра «не добрано 2 млн» и в
    # одиннадцать вечера «не добрано 2 млн» — совершенно разные ситуации,
    # хотя недобор один и тот же. Поэтому считается не сам недобор, а темп,
    # которого он требует от остатка суток:
    #
    #   давление = (доля недобора) / (доля оставшегося времени)
    #
    # Пока давление ниже единицы, провайдер идёт по графику, цель молчит и
    # возвращает всем одинаковый ноль — эшелон оказывается ничейным, и решение
    # честно уходит в младший, к долям и конверсии. Как только график сорван,
    # цель включается, и тем сильнее, чем больше отставание.
    #
    # Без этого гейта любое, даже плановое, отставание одного провайдера
    # забирало бы ему весь трафик с первой же заявки дня.
    class TurnoverCommitment < Base
      SECONDS_IN_DAY = 86_400.0
      MIN_REMAINING = 0.02

      def raw_score(context)
        target = context.provider.daily_turnover_min
        return nil if target.nil? || target.zero?

        pressure = pressure_for(context, target)
        return 0.0 if pressure.nil? || pressure <= activation_pressure

        ((pressure - activation_pressure) / activation_pressure).clamp(0.0, 1.0)**exponent
      end

      def explain(context)
        target = context.provider.daily_turnover_min
        return "обязательство по минимальному обороту не задано" if target.nil? || target.zero?

        gap = context.state.turnover_min_gap
        return "минимальный оборот #{target} выполнен (#{context.state.daily_amount})" if gap.nil? || gap.zero?

        pressure = pressure_for(context, target)
        remaining = remaining_day_fraction(context)
        base = "не добрано #{gap} до обязательства #{target}"
        return "#{base}, времени суток не определить — цель не активирована" if pressure.nil?

        verdict = pressure <= activation_pressure ? "идёт по графику, цель не активирована" : "график сорван"
        "#{base}; до конца суток #{pct(remaining)}% времени, требуемый темп " \
          "#{pressure.round(2)}x от планового — #{verdict}"
      end

      private

      # Доля недобора, делённая на долю оставшегося времени.
      # 1.0 — ровно по графику, больше — отставание.
      def pressure_for(context, target)
        gap = context.state.turnover_min_gap
        return nil if gap.nil? || gap.zero?

        remaining = remaining_day_fraction(context)
        return nil if remaining.nil?

        gap.ratio_of(target) / [remaining, MIN_REMAINING].max
      end

      # Сколько суток осталось, в долях. Если времени не видно — цель молчит,
      # а не срабатывает наугад.
      def remaining_day_fraction(context)
        at = context.at
        return nil if at.nil? || !at.to_f.finite?

        moment = Time.at(at.to_f)
        elapsed = (moment - Time.new(moment.year, moment.month, moment.day, 0, 0, 0, moment.utc_offset)) / SECONDS_IN_DAY
        (1.0 - elapsed).clamp(0.0, 1.0)
      end

      def exponent = setting("urgency_exponent", 0.5).to_f

      # При каком превышении планового темпа цель включается.
      # 1.0 — ровно когда провайдер начал отставать от графика.
      def activation_pressure = setting("activation_pressure", 1.0).to_f
    end
  end
end
