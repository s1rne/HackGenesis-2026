# frozen_string_literal: true

module Routing
  # Симуляция ответа провайдера.
  #
  # Два разных события, которые легко перепутать:
  #   * отказ в приёме — провайдер не взял заявку в работу, и каскад идёт дальше;
  #   * итог выплаты — approved / rejected / expired у того, кто заявку взял.
  #
  # История кейса разделяет их довольно явно: у одобренных операций задержка
  # порядка 70 секунд, у rejected — единицы секунд, у expired — сотни. Быстрый
  # rejected по смыслу и есть технический отказ в приёме, поэтому доля отказов
  # калибруется по истории, а не берётся из головы.
  #
  # Генератор случайных чисел детерминирован: зерно собирается из зерна прогона,
  # идентификатора операции, провайдера и номера попытки. Один и тот же вход
  # даёт один и тот же выход на любой машине — иначе результат невозможно
  # ни воспроизвести, ни обсудить на защите.
  class Simulator
    OUTCOMES = %i[approved rejected expired].freeze

    Response = Struct.new(:outcome, :latency_sec, :refused, keyword_init: true) do
      def approved? = outcome == :approved
      def refused? = !!refused
    end

    def initialize(config, calibration: nil)
      @config = config
      @calibration = calibration
      @seed = config.fetch("run", "seed", default: 0).to_i
      @settings = config.section("simulation")
      @latency = @settings.fetch("latency", {})
    end

    def enabled? = @settings.fetch("enabled", true)

    def respond(operation:, provider:, state:, attempt_no:)
      rng = rng_for(operation, provider, attempt_no)
      success_rate = success_rate_for(provider)
      draw = rng.rand

      if draw < success_rate
        Response.new(outcome: :approved, latency_sec: latency_for(provider, rng, :approved), refused: false)
      else
        outcome = failure_outcome(rng)
        Response.new(outcome: outcome,
                     latency_sec: latency_for(provider, rng, outcome),
                     refused: refusal?(outcome))
      end
    end

    private

    # Зерно, устойчивое к порядку обработки: оно зависит только от того, что
    # за операция, к какому провайдеру и какой по счёту попыткой. Переставить
    # заявки местами и получить другой результат по той же паре нельзя.
    def rng_for(operation, provider, attempt_no)
      material = "#{@seed}|#{operation.id}|#{provider.id}|#{attempt_no}"
      Random.new(Digest::MD5.hexdigest(material)[0, 12].to_i(16))
    end

    def success_rate_for(provider)
      observed = @calibration&.success_rate_for(provider.id)
      declared = provider.conversion_24h
      return (observed || declared || 0.8).to_f.clamp(0.0, 1.0) unless observed && declared

      # Заявленная конверсия и наблюдённая по истории смешиваются: заявленная
      # работает как априорная оценка, история её уточняет.
      weight = @settings.fetch("history_weight", 0.5).to_f.clamp(0.0, 1.0)
      (((1 - weight) * declared) + (weight * observed)).clamp(0.0, 1.0)
    end

    def failure_outcome(rng)
      expired_share = @settings.fetch("expired_share_of_failures", 0.35).to_f
      rng.rand < expired_share ? :expired : :rejected
    end

    # Каскад продолжается только по тем исходам, которые описаны как отказ
    # в приёме. Настройка — в конфигурации, чтобы поведение можно было
    # переключить, не трогая код.
    def refusal?(outcome)
      Array(@settings.fetch("cascade_on", %w[rejected expired])).map(&:to_s).include?(outcome.to_s)
    end

    def latency_for(provider, rng, outcome)
      case outcome
      when :expired
        @latency.fetch("expired_sec", 540).to_i
      when :rejected
        @latency.fetch("rejected_sec", 8).to_i
      else
        base = provider.avg_latency_sec || @latency.fetch("base_sec", 30).to_f
        spread = @latency.fetch("spread", 0.4).to_f
        (base * (1.0 - spread + (2 * spread * rng.rand))).round.clamp(1, 3600)
      end
    end
  end
end
