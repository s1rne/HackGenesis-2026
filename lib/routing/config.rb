# frozen_string_literal: true

module Routing
  # Конфигурация маршрутизации.
  #
  # Ключевое свойство: любое правило, вес, порог и порядок разрешения конфликтов
  # задаются здесь, а не в коде. Код умеет «как считать», конфигурация решает
  # «что считать важным». Поэтому смена стратегии — это правка YAML, а не релиз.
  #
  # Файл конфигурации при этом необязателен: DEFAULTS — рабочий профиль сам по
  # себе, а YAML лишь накладывается поверх глубоким слиянием.
  class Config
    DEFAULTS = {
      "version" => 1,
      "profile" => "balanced",
      "run" => {
        "period" => nil,
        "max_attempts" => 3,
        "fallback_provider" => "spacepayments",
        "seed" => 20_260_906,
        "exhausted_pool_policy" => "retry_best",
        "capacity_exhausted_policy" => "fallback",
        "timeout_policy" => "pending_success"
      },
      "ingest" => {
        "field_aliases" => {},
        "bank_aliases" => {},
        "defaults" => {
          "conversion_24h" => 0.8,
          "avg_latency_sec" => 25.0,
          "traffic_percentage" => nil
        }
      },
      "hard_constraints" => {
        "provider_status" => { "enabled" => true },
        "traffic_share" => { "enabled" => true },
        "currency" => { "enabled" => true },
        "amount_range" => { "enabled" => true },
        "daily_amount_limit" => { "enabled" => true },
        "daily_turnover_max" => { "enabled" => true },
        "in_progress_limits" => { "enabled" => true },
        "bank_filter" => { "enabled" => true, "unknown_bank_policy" => "allow" },
        "margin" => { "enabled" => true },
        "requisites" => { "enabled" => true },
        "rate_limit" => { "enabled" => true, "window_sec" => 60 }
      },
      "strategies" => {
        "turnover_commitment" => { "enabled" => true, "weight" => 1.2, "tier" => 1 },
        "count_share" => { "enabled" => true, "weight" => 1.0, "tier" => 2 },
        "volume_share" => { "enabled" => true, "weight" => 0.8, "tier" => 2 },
        "conversion" => { "enabled" => true, "weight" => 1.0, "tier" => 2,
                          "estimator" => "wilson", "confidence" => 0.95, "prior_weight" => 20 },
        "amount_band" => { "enabled" => true, "weight" => 0.9, "tier" => 2, "bands" => [] },
        "cascade_priority" => { "enabled" => true, "weight" => 0.6, "tier" => 3 },
        "load_balance" => { "enabled" => true, "weight" => 0.7, "tier" => 3 },
        "margin" => { "enabled" => true, "weight" => 0.4, "tier" => 3 }
      },
      "scoring" => {
        "mode" => "lexicographic_weighted",
        "tier_epsilon" => 0.05,
        "tie_break" => %w[cascade_priority conversion provider_id]
      },
      "goal_relaxation" => {
        "enabled" => true,
        "reallocate_unreachable_share" => true
      },
      "simulation" => {
        "enabled" => true,
        "cascade_on" => %w[rejected],
        "expired_share_of_failures" => 0.5,
        "history_weight" => 0.5,
        "latency" => { "base_sec" => 30.0, "spread" => 0.4, "rejected_sec" => 46.0, "expired_sec" => 540.0 }
      },
      "analytics" => {
        "share_drift_alert_pct" => 10.0,
        "utilization_alert_pct" => 80.0,
        "conversion_alert" => 0.6,
        "max_recommendations" => 12
      }
    }.freeze

    attr_reader :data, :path

    def self.load(path = nil)
      return new(DEFAULTS) if path.nil?
      raise ConfigError, "файл конфигурации не найден: #{path}" unless File.exist?(path)

      loaded = begin
        YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: true) || {}
      rescue Psych::SyntaxError => e
        raise ConfigError, "конфигурация #{path} не разбирается как YAML: #{e.message}"
      end
      raise ConfigError, "конфигурация #{path} должна быть словарём" unless loaded.is_a?(Hash)

      merged = deep_merge(DEFAULTS, stringify(loaded))
      check_version!(merged["version"], path)
      config = new(merged, path: path)
      config.validate!
      config
    end

    # Версия схемы конфигурации. Проверяется, а не игнорируется: если файл
    # написан под другую версию, лучше сказать об этом сразу, чем молча
    # применить половину настроек и получить необъяснимый результат.
    SUPPORTED_VERSIONS = [1].freeze

    def self.check_version!(version, path)
      return if version.nil? || SUPPORTED_VERSIONS.include?(version.to_i)

      raise ConfigError, "конфигурация #{path} объявлена версией #{version}, " \
                         "поддерживаются: #{SUPPORTED_VERSIONS.join(', ')}"
    end

    def self.stringify(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_s, stringify(v)] }
      when Array then value.map { |v| stringify(v) }
      else value
      end
    end

    # Глубокое слияние с одной особенностью: порядок ключей задаёт override.
    #
    # Порядок здесь не косметика. Жёсткие ограничения проверяются до первого
    # нарушения, и именно первое попадает в отчёт как причина отказа. Автор
    # конфигурации, переставив правила, меняет то, какую причину увидит
    # человек, — и он вправе на это рассчитывать.
    def self.deep_merge(base, override)
      merged = {}
      override.each_key do |key|
        merged[key] = if base[key].is_a?(Hash) && override[key].is_a?(Hash)
                        deep_merge(base[key], override[key])
                      else
                        override[key]
                      end
      end
      base.each { |key, value| merged[key] = value unless merged.key?(key) }
      merged
    end

    def initialize(data, path: nil)
      @data = self.class.stringify(data)
      @path = path
    end

    SCORING_MODES = %w[weighted lexicographic lexicographic_weighted].freeze
    TIE_BREAK_KEYS = %w[provider_id cascade_priority conversion load margin].freeze
    EXHAUSTED_POLICIES = %w[retry_best fallback].freeze
    CAPACITY_POLICIES = %w[fallback route_anyway].freeze
    TIMEOUT_POLICIES = %w[pending_success retry_next].freeze

    # Проверка настроек до первого прогона.
    #
    # Раньше конфигурация с mode: bananas и отрицательным эпсилоном спокойно
    # проходила сборку, печаталась на экране как рабочая и падала уже поштучно
    # на каждой заявке — после того, как негодные файлы были записаны на диск.
    # Ошибка в настройках должна останавливать прогон в самом начале.
    def validate!
      problems = []
      problems.concat(validate_scoring)
      problems.concat(validate_weights)
      problems.concat(validate_run)
      return self if problems.empty?

      raise ConfigError, "конфигурация#{path ? " #{path}" : ''} негодна:\n  - #{problems.join("\n  - ")}"
    end

    private

    def validate_scoring
      problems = []
      mode = fetch("scoring", "mode").to_s
      unless SCORING_MODES.include?(mode)
        problems << "scoring.mode = #{mode.inspect}, допустимо: #{SCORING_MODES.join(', ')}"
      end

      epsilon = fetch("scoring", "tier_epsilon")
      unless epsilon.is_a?(Numeric) && epsilon >= 0
        problems << "scoring.tier_epsilon = #{epsilon.inspect}, ожидалось неотрицательное число"
      end

      unknown = Array(fetch("scoring", "tie_break")).map(&:to_s) - TIE_BREAK_KEYS - enabled_strategy_ids
      unless unknown.empty?
        problems << "scoring.tie_break ссылается на неизвестные ключи: #{unknown.join(', ')}; " \
                    "допустимы #{TIE_BREAK_KEYS.join(', ')} или идентификатор включённой цели"
      end
      problems
    end

    def validate_weights
      section("strategies").filter_map do |id, settings|
        next unless settings.is_a?(Hash) && settings["enabled"]

        weight = settings["weight"]
        tier = settings["tier"]
        if !weight.nil? && (!weight.is_a?(Numeric) || weight.negative?)
          next "strategies.#{id}.weight = #{weight.inspect}, ожидалось неотрицательное число"
        end
        next unless !tier.nil? && (!tier.is_a?(Integer) || tier < 1)

        "strategies.#{id}.tier = #{tier.inspect}, ожидалось целое от 1"
      end
    end

    def validate_run
      problems = []
      policy = fetch("run", "exhausted_pool_policy").to_s
      unless EXHAUSTED_POLICIES.include?(policy)
        problems << "run.exhausted_pool_policy = #{policy.inspect}, допустимо: #{EXHAUSTED_POLICIES.join(', ')}"
      end

      capacity = fetch("run", "capacity_exhausted_policy").to_s
      unless CAPACITY_POLICIES.include?(capacity)
        problems << "run.capacity_exhausted_policy = #{capacity.inspect}, допустимо: #{CAPACITY_POLICIES.join(', ')}"
      end

      timeout = fetch("run", "timeout_policy").to_s
      unless TIMEOUT_POLICIES.include?(timeout)
        problems << "run.timeout_policy = #{timeout.inspect}, допустимо: #{TIMEOUT_POLICIES.join(', ')}"
      end

      attempts = fetch("run", "max_attempts")
      unless attempts.is_a?(Integer) && attempts.positive?
        problems << "run.max_attempts = #{attempts.inspect}, ожидалось целое больше нуля"
      end
      problems
    end

    public

    def fetch(*keys, default: nil)
      keys.flatten.map(&:to_s).reduce(@data) do |node, key|
        return default unless node.is_a?(Hash) && node.key?(key)

        node[key]
      end
    end

    def section(*keys) = fetch(*keys, default: {}) || {}

    def strategy(id) = section("strategies", id)
    def constraint(id) = section("hard_constraints", id)

    def strategy_enabled?(id) = strategy(id).fetch("enabled", false)
    def constraint_enabled?(id) = constraint(id).fetch("enabled", true)

    def enabled_strategy_ids
      section("strategies").select { |_id, cfg| cfg.is_a?(Hash) && cfg["enabled"] }.keys
    end

    def enabled_constraint_ids
      section("hard_constraints").reject { |_id, cfg| cfg.is_a?(Hash) && cfg["enabled"] == false }.keys
    end

    # Профиль — именованный набор перекрытий поверх базовой конфигурации.
    # Так одна и та же кодовая база проигрывается в режимах «максимум конверсии»,
    # «строго по долям» или «сначала выполнить обязательства по обороту».
    def with_profile(name)
      return self if name.nil? || name.to_s.empty?

      overrides = section("profiles", name)
      raise ConfigError, "профиль #{name} не описан в конфигурации" if overrides.empty?

      merged = self.class.deep_merge(@data, overrides)
      merged["profile"] = name.to_s
      self.class.new(merged, path: path)
    end

    def profiles = section("profiles").keys

    def merge(overrides) = self.class.new(self.class.deep_merge(@data, self.class.stringify(overrides)), path: path)
  end
end
