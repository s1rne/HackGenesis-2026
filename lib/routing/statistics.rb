# frozen_string_literal: true

module Routing
  # Классическая статистика без единой обучаемой модели.
  #
  # Это осознанное ограничение кейса, но оно же и правильное решение по сути:
  # на выборке из десятков операций любая модель переобучится, а нижняя граница
  # доверительного интервала честно скажет «данных мало, не доверяй пока».
  # Каждая формула здесь проверяема на бумаге — что важно, когда роутер
  # объясняет решение деньгами.
  module Statistics
    # Квантили стандартного нормального распределения для типовых уровней
    # доверия. Таблица вместо вычисления обратной функции ошибок: значений
    # нужно три, а точность важнее универсальности.
    Z_SCORES = { 0.80 => 1.2816, 0.90 => 1.6449, 0.95 => 1.9600, 0.98 => 2.3263, 0.99 => 2.5758 }.freeze

    module_function

    def z_for(confidence)
      Z_SCORES.fetch(confidence.to_f.round(2)) do
        Z_SCORES.min_by { |level, _| (level - confidence.to_f).abs }.last
      end
    end

    # Нижняя граница интервала Вильсона для доли успехов.
    #
    # Провайдер с 3 успехами из 3 не лучше провайдера с 90 из 100, хотя «сырая»
    # конверсия у первого выше. Вильсон разводит их: 1.00 против 0.82 у первого
    # и 0.90 против 0.83 у второго при 95%. Именно поэтому мы сравниваем
    # провайдеров по нижней границе, а не по наблюдаемой частоте.
    def wilson_lower_bound(successes, trials, confidence = 0.95)
      return 0.0 if trials.nil? || trials <= 0

      z = z_for(confidence)
      n = trials.to_f
      phat = successes.to_f / n
      denominator = 1 + ((z**2) / n)
      centre = phat + ((z**2) / (2 * n))
      spread = z * Math.sqrt((phat * (1 - phat) / n) + ((z**2) / (4 * n**2)))
      ((centre - spread) / denominator).clamp(0.0, 1.0)
    end

    # Сглаживание наблюдений априорной оценкой: заявленная конверсия работает
    # как `prior_weight` виртуальных наблюдений и постепенно вытесняется фактом.
    def blended_counts(prior_rate, prior_weight, successes, trials)
      prior_rate = (prior_rate || 0.0).clamp(0.0, 1.0)
      prior_weight = prior_weight.to_f.clamp(0.0, 1e6)
      [ (prior_rate * prior_weight) + successes.to_i, prior_weight + trials.to_i ]
    end

    # Экспоненциально взвешенное среднее: свежие наблюдения весят больше.
    def ewma(values, alpha = 0.3)
      return nil if values.nil? || values.empty?

      values.reduce(nil) { |acc, value| acc.nil? ? value.to_f : (alpha * value.to_f) + ((1 - alpha) * acc) }
    end

    # Приведение набора значений к 0..1. Если все значения совпали, различать
    # провайдеров по этому фактору нечем — возвращаем нейтральные 0.5,
    # чтобы фактор не притворялся значимым.
    def min_max_normalize(values)
      finite = values.compact.select { |v| v.to_f.finite? }
      return values.map { |v| v.nil? ? nil : 0.5 } if finite.empty?

      min = finite.min.to_f
      max = finite.max.to_f
      span = max - min
      return values.map { |v| v.nil? ? nil : 0.5 } if span.abs < 1e-12

      values.map { |v| v.nil? ? nil : ((v.to_f - min) / span).clamp(0.0, 1.0) }
    end

    # Метод наибольших остатков: раскладывает целое N по долям так, что сумма
    # ровно равна N. На десяти заявках это разница между «40% = 4 заявки»
    # и «40% = 3 или 5, как повезёт округлению».
    def largest_remainder(shares, total)
      return {} if shares.empty? || total <= 0

      exact = shares.transform_values { |share| share.to_f * total }
      floors = exact.transform_values(&:floor)
      remainder = total - floors.values.sum
      ranked = exact.sort_by { |key, value| [-(value - value.floor), key.to_s] }
      ranked.first(remainder.clamp(0, ranked.size)).each { |key, _| floors[key] += 1 }
      floors
    end

    # Индекс Херфиндаля–Хиршмана: насколько трафик сосредоточен на одном
    # провайдере. 1.0 — весь объём у одного, 1/k — идеально ровно.
    def concentration(shares)
      values = shares.map(&:to_f).reject(&:zero?)
      return 0.0 if values.empty?

      total = values.sum
      return 0.0 if total.zero?

      values.sum { |v| (v / total)**2 }
    end
  end
end
