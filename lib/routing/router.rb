# frozen_string_literal: true

module Routing
  # Фасад: собирает конвейер из настроек и прогоняет через него очередь.
  #
  # Здесь нет ни одного решения о том, кого выбрать, — только сборка.
  # Правила живут в constraints, цели в strategies, согласование в Scorer,
  # порядок попыток в Cascade. Заменить любую часть можно, не трогая остальные.
  class Router
    attr_reader :config, :fleet, :calibration, :issues, :meta, :constraints, :strategies

    def self.build(config:, providers_path:, history_path: nil, issues: nil)
      issues ||= Ingest::Issues.new
      loader = Ingest::Loader.new(config, issues: issues)
      fleet = loader.load_fleet(providers_path)
      history = loader.load_history(history_path)
      new(config: config, fleet: fleet,
          calibration: Calibration.new(history, config),
          issues: issues, meta: loader.meta)
    end

    def initialize(config:, fleet:, calibration: nil, issues: nil, meta: {})
      @config = config
      @fleet = fleet
      @calibration = calibration
      @issues = issues || Ingest::Issues.new
      @meta = meta || {}
      @constraints = Constraints::Registry.build(config)
      @strategies = Strategies::Registry.build(config)
      raise ConfigError, "не включена ни одна цель маршрутизации" if @strategies.empty?

      @scorer = Scorer.new(@strategies, config)
      @simulator = Simulator.new(config, calibration: @calibration)
    end

    def route_all(operations)
      clock = Clock.new(started_at: snapshot_time)
      cascade = Cascade.new(fleet: @fleet, constraints: @constraints, scorer: @scorer,
                            simulator: @simulator, config: @config, clock: clock,
                            calibration: @calibration)

      routed = operations.map do |operation|
        cascade.route(operation)
      rescue Error => e
        # Одна сломанная заявка не должна ронять прогон: остальные девяносто
        # девять должны доехать до файла, а причина — попасть в замечания.
        @issues.error("routing", "заявка #{operation.id}: #{e.message}")
        failed_decision(operation, e)
      end

      if clock.out_of_order_count.positive?
        @issues.info("routing", "заявок с отметкой раньше предыдущей: #{clock.out_of_order_count}; " \
                                "окно интенсивности считается по времени заявки, " \
                                "а не по её месту в файле")
      end

      if clock.anchored_by_fallback
        anchor = Clock::FALLBACK_ANCHOR.strftime("%Y-%m-%d %H:%M UTC")
        @issues.warning("routing", "во входных данных нет ни snapshot_at, ни created_at: " \
                                   "часы прогона начаты с условной отметки #{anchor}, " \
                                   "правила, зависящие от времени суток, отсчитываются от неё")
      end

      routed
    end

    def snapshot_time
      stamp = @meta["snapshot_at"] || @meta["generated_at"]
      return nil if stamp.nil?

      Time.parse(stamp.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Период отчёта — это дата заявок, а не дата снимка провайдеров.
    # Снимок может быть снят заранее: если брать дату из него, в отчёте по
    # очереди от шестого сентября будет стоять тридцатое июля.
    def period(operations = nil)
      configured = @config.fetch("run", "period")
      return configured.to_s if configured

      dates = Array(operations).filter_map { |operation| operation.created_at&.strftime("%Y-%m-%d") }
      return dates.tally.max_by { |_, count| count }.first unless dates.empty?

      (snapshot_time || Clock::FALLBACK_ANCHOR).strftime("%Y-%m-%d")
    end

    def describe
      {
        "profile" => @config.fetch("profile"),
        "scoring_mode" => @config.fetch("scoring", "mode"),
        "hard_constraints" => @constraints.map(&:id),
        "strategies" => @strategies.map { |s| { "id" => s.id, "weight" => s.weight, "tier" => s.tier } },
        "providers" => @fleet.ids,
        "history_operations" => @calibration&.size.to_i
      }
    end

    private

    def failed_decision(operation, error)
      Decision.new(
        operation: operation,
        selected_provider: nil,
        attempts: [{ "provider" => "-", "decision" => "skipped", "reason" => "routing_error",
                     "details" => error.message }],
        simulated_result: "rejected",
        latency_sec: 0,
        selection_reason: "routing_error",
        selection_details: error.message,
        strategy_profile: @config.fetch("profile")
      )
    end
  end
end
