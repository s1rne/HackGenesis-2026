# frozen_string_literal: true

module Routing
  # Пул провайдеров со своими состояниями плюс нормализованные цели по долям.
  #
  # Цели нормализуются намеренно: в данных traffic_percentage может в сумме
  # давать 95 или 110 — так бывает, когда провайдера отключили и доли не
  # пересчитали. Мы приводим сумму к 100% и пишем об этом замечание, иначе
  # «отклонение от целевой доли» в отчёте становится бессмысленным числом.
  class Fleet
    attr_reader :providers, :states, :issues

    def initialize(providers, issues: Ingest::Issues.new)
      @providers = providers
      @states = providers.to_h { |provider| [provider.id, ProviderState.new(provider)] }
      @issues = issues
      @count_targets = normalize_targets(:traffic_percentage, "traffic_percentage")
      @volume_targets = normalize_targets(:volume_share_pct, "volume_share_pct", fallback: @count_targets)
    end

    def [](id) = @states[id]
    def state_for(id) = @states.fetch(id) { raise Error, "неизвестный провайдер #{id}" }
    def provider_for(id) = @providers.find { |p| p.id == id }
    def ids = @providers.map(&:id)
    def each_state(&block) = @states.each_value(&block)

    # Внешние провайдеры — все, кроме self-провайдера: цели по долям и
    # аналитика распределения считаются по ним, self стоит вне конкурса.
    def routable = @providers.reject(&:self_provider?)
    def self_providers = @providers.select(&:self_provider?)

    # Целевая доля по количеству, 0..1.
    #
    # `among` — провайдеры, доступные прямо сейчас. Если он задан, цели
    # пересчитываются только на них: доля недоступного провайдера не исчезает,
    # а перераспределяется между теми, кто может принять заявку. Без этого
    # недостижимая цель тянула бы весь пул вниз — все выглядели бы
    # «перевыполнившими план», хотя выполнять его физически некому.
    def count_target(id, among: nil) = target_from(@count_targets, id, among)

    # Целевая доля по объёму, 0..1.
    def volume_target(id, among: nil) = target_from(@volume_targets, id, among)

    # Кого пришлось исключить из целей и какая доля ушла на перераспределение.
    def unreachable_targets(among)
      available = Array(among)
      routable.reject { |p| available.include?(p.id) }
              .to_h { |p| [p.id, @count_targets.fetch(p.id, 0.0)] }
              .reject { |_, share| share.zero? }
    end

    def total_selected_count = @states.each_value.sum(&:selected_count)

    def total_selected_amount
      @states.each_value.reduce(Money.zero) { |acc, state| acc + state.selected_amount }
    end

    def actual_count_share(id)
      total = total_selected_count
      return 0.0 if total.zero?

      state_for(id).selected_count.to_f / total
    end

    def actual_volume_share(id)
      total = total_selected_amount
      return 0.0 if total.zero?

      state_for(id).selected_amount.ratio_of(total)
    end

    def snapshot(at = Float::INFINITY) = @states.values.map { |state| state.to_h(at) }

    private

    def target_from(table, id, among)
      return table.fetch(id, 0.0) if among.nil?

      subset = Array(among)
      return 0.0 unless subset.include?(id)

      total = subset.sum { |key| table.fetch(key, 0.0) }
      return 1.0 / subset.size if total <= 0

      table.fetch(id, 0.0) / total
    end

    def normalize_targets(attribute, label, fallback: nil)
      raw = routable.to_h { |provider| [provider.id, provider.public_send(attribute)] }
      present = raw.reject { |_, value| value.nil? }

      if present.empty?
        return fallback.dup if fallback

        # Ни у кого нет цели — считаем распределение равномерным.
        share = routable.empty? ? 0.0 : 1.0 / routable.size
        return routable.to_h { |provider| [provider.id, share] }
      end

      total = present.values.sum.to_f
      if total <= 0
        share = 1.0 / present.size
        return present.transform_values { share }
      end

      if (total - 100.0).abs > 0.5 && (total - 1.0).abs > 0.005
        issues.warning("providers", "сумма #{label} по провайдерам равна #{total.round(2)}, доли нормализованы к 100%")
      end

      normalized = present.transform_values { |value| value / total }
      raw.each_key { |id| normalized[id] ||= 0.0 }
      normalized
    end
  end
end
