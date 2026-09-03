# frozen_string_literal: true

module Routing
  module Strategies
    # Стратегия 5: приоритизация по конверсии.
    #
    # Сравнивать провайдеров по conversion_24h «как есть» опасно: это одно
    # число без указания, на скольких заявках оно получено. Мы смешиваем
    # заявленную конверсию с фактом текущего прогона (заявленная работает как
    # prior_weight виртуальных наблюдений) и берём нижнюю границу интервала
    # Вильсона. Провайдер, который только что отказал дважды подряд, теряет
    # приоритет сразу, а не после накопления «статистически значимой» выборки.
    class Conversion < Base
      def raw_score(context)
        prior = context.provider.conversion_24h
        state = context.state
        finished = state.approved_count + state.declined_count + state.expired_count

        return prior if estimator == "raw" || (prior.nil? && finished.zero?)

        successes, trials = Statistics.blended_counts(prior, prior_weight, state.approved_count, finished)
        return prior if trials.zero?

        Statistics.wilson_lower_bound(successes, trials, confidence)
      end

      def explain(context)
        state = context.state
        finished = state.approved_count + state.declined_count + state.expired_count
        estimate = raw_score(context)
        base = "конверсия #{pct(context.provider.conversion_24h || 0)}% заявлена"
        return "#{base}, оценка #{pct(estimate || 0)}%" if finished.zero?

        "#{base}, в прогоне #{state.approved_count} из #{finished}, " \
          "нижняя граница #{pct(estimate || 0)}% при доверии #{pct(confidence)}%"
      end

      private

      def estimator = setting("estimator", "wilson").to_s
      def confidence = setting("confidence", 0.95).to_f
      def prior_weight = setting("prior_weight", 20).to_f
    end
  end
end
