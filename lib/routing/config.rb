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
        "share_basis" => "selected"
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
        "reallocate_unreachable_share" => true,
        "ladder" => %w[drop_tier_1 drop_soft_goals fallback_provider]
      },
      "simulation" => {
        "enabled" => true,
        "decline_uses_conversion" => true,
        "timeout_share_of_failures" => 0.25,
        "expire_share_of_failures" => 0.25,
        "latency" => { "base_sec" => 12.0, "jitter_sec" => 18.0, "timeout_sec" => 60.0 }
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

      new(deep_merge(DEFAULTS, stringify(loaded)), path: path)
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
