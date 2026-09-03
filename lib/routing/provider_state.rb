# frozen_string_literal: true

module Routing
  # Изменяемое состояние провайдера в ходе прогона.
  #
  # Жизненный цикл одной попытки: reserve -> (settle_approved | settle_declined).
  # Резерв занимает слот in-progress и реквизит; расчёт либо переводит сумму
  # в дневной оборот, либо возвращает всё назад. Благодаря этому отказ
  # провайдера не оставляет за собой «повисшие» занятые лимиты — то самое
  # корректное обновление состояния, без которого каскад начинает врать.
  class ProviderState
    attr_reader :provider, :daily_amount, :in_progress_count, :in_progress_amount,
                :available_requisites, :selected_count, :selected_amount,
                :attempt_count, :approved_count, :approved_amount,
                :declined_count, :expired_count, :skipped_count, :request_times

    # zeroed: начать сутки с нуля вместо снимка из входных данных.
    # Нужно для контрфактического реплея истории: она относится к другому дню,
    # и стартовать с сегодняшнего оборота значило бы сравнивать несравнимое.
    def initialize(provider, zeroed: false)
      @provider = provider
      @daily_amount = zeroed ? Money.zero : (provider.initial_daily_amount || Money.zero)
      @in_progress_count = zeroed ? 0 : (provider.initial_in_progress_count || 0)
      @in_progress_amount = zeroed ? Money.zero : (provider.initial_in_progress_amount || Money.zero)
      @available_requisites = provider.initial_requisites
      @selected_count = 0
      @selected_amount = Money.zero
      @attempt_count = 0
      @approved_count = 0
      @approved_amount = Money.zero
      @declined_count = 0
      @expired_count = 0
      @skipped_count = 0
      @request_times = []
      @reservations = {}
    end

    def id = provider.id

    # --- интенсивность -------------------------------------------------------

    def requests_in_window(at, window_sec = 60.0)
      @request_times.count { |t| t > at - window_sec && t <= at }
    end

    def record_request(at)
      @request_times << at
      # Окно скользящее: всё, что старше пяти минут, на решение уже не влияет,
      # но список растёт линейно по числу заявок — подрезаем его.
      @request_times.shift while @request_times.size > 1 && @request_times.first < at - 300.0
      self
    end

    # --- резерв и расчёт -----------------------------------------------------

    def reserve(operation, at:)
      raise RuleError.new("двойной резерв операции #{operation.id}", rule: "provider_state") if @reservations.key?(operation.id)

      took_requisite = !@available_requisites.nil? && @available_requisites.positive?
      @available_requisites -= 1 if took_requisite
      @in_progress_count += 1
      @in_progress_amount += operation.amount
      @attempt_count += 1
      record_request(at)
      @reservations[operation.id] = { amount: operation.amount, requisite: took_requisite }
      self
    end

    def settle_approved(operation)
      release(operation)
      @daily_amount += operation.amount
      @approved_count += 1
      @approved_amount += operation.amount
      self
    end

    def settle_failed(operation, result)
      release(operation)
      case result
      when :expired then @expired_count += 1
      else @declined_count += 1
      end
      self
    end

    # Провайдер выбран как итоговый для операции — это и есть «доля трафика».
    def record_selection(operation)
      @selected_count += 1
      @selected_amount += operation.amount
      self
    end

    def record_skip = (@skipped_count += 1) && self

    # --- загрузка ------------------------------------------------------------

    def daily_utilization
      limit = provider.daily_amount_limit
      return 0.0 if limit.nil? || limit.zero?

      daily_amount.ratio_of(limit)
    end

    def in_progress_count_utilization
      limit = provider.in_progress_count_limit
      return 0.0 if limit.nil? || limit.zero?

      in_progress_count.to_f / limit
    end

    def in_progress_amount_utilization
      limit = provider.in_progress_amount_limit
      return 0.0 if limit.nil? || limit.zero?

      in_progress_amount.ratio_of(limit)
    end

    def requisite_utilization
      return 0.0 if provider.initial_requisites.nil? || provider.initial_requisites.zero?

      1.0 - (available_requisites.to_f / provider.initial_requisites)
    end

    def rate_utilization(at)
      limit = provider.requests_per_minute_limit
      return 0.0 if limit.nil? || limit.zero?

      requests_in_window(at).to_f / limit
    end

    # Одна цифра «насколько провайдер загружен» — максимум по всем измерениям.
    # Максимум, а не среднее: узкое место определяет именно самый нагруженный
    # лимит, и усреднение его бы замаскировало.
    def load_factor(at = Float::INFINITY)
      factors = [daily_utilization, in_progress_count_utilization,
                 in_progress_amount_utilization, requisite_utilization]
      factors << rate_utilization(at) if at.finite?
      factors.max.clamp(0.0, 1.0)
    end

    def headroom_amount
      limit = provider.daily_amount_limit
      return nil if limit.nil?

      remaining = limit - daily_amount
      remaining.negative? ? Money.zero : remaining
    end

    def turnover_min_gap
      target = provider.daily_turnover_min
      return nil if target.nil?

      gap = target - daily_amount
      gap.negative? ? Money.zero : gap
    end

    def observed_conversion
      finished = approved_count + declined_count + expired_count
      return nil if finished.zero?

      approved_count.to_f / finished
    end

    def to_h(at = Float::INFINITY)
      {
        provider: id,
        daily_amount: daily_amount.as_json,
        daily_limit: provider.daily_amount_limit&.as_json,
        daily_utilization_pct: (daily_utilization * 100).round(2),
        in_progress_count: in_progress_count,
        in_progress_amount: in_progress_amount.as_json,
        available_requisites: available_requisites,
        selected_count: selected_count,
        selected_amount: selected_amount.as_json,
        attempts: attempt_count,
        approved: approved_count,
        declined: declined_count,
        expired: expired_count,
        load_factor: load_factor(at).round(4)
      }.compact
    end

    private

    def release(operation)
      reservation = @reservations.delete(operation.id)
      return self unless reservation

      @in_progress_count -= 1
      @in_progress_amount -= reservation[:amount]
      @available_requisites += 1 if reservation[:requisite]
      self
    end
  end
end
