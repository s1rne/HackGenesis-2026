# frozen_string_literal: true

module Routing
  # Калибровка по истории операций.
  #
  # Заявленная conversion_24h — это одно число без указания, на скольких
  # заявках оно получено. История даёт факт: сколько заявок провайдер принял,
  # сколько одобрил, за какое время. Мы не обучаем на ней модель — обучать
  # нечему и не на чем, сто строк. Мы считаем частоты, доверительные интервалы
  # и средние задержки: всё проверяемо на бумаге и объяснимо на защите.
  class Calibration
    SUCCESS = "approved"

    attr_reader :rows, :by_provider

    def initialize(rows, config)
      @rows = Array(rows)
      @config = config
      @by_provider = @rows.group_by { |row| row[:provider] }.reject { |id, _| id.nil? || id.empty? }
    end

    def empty? = @rows.empty?
    def size = @rows.size

    def providers = @by_provider.keys.sort

    def counts_for(provider_id)
      rows = @by_provider.fetch(provider_id, [])
      {
        total: rows.size,
        approved: rows.count { |r| r[:status] == SUCCESS },
        rejected: rows.count { |r| r[:status] == "rejected" },
        expired: rows.count { |r| r[:status] == "expired" }
      }
    end

    # Наблюдённая доля одобренных. nil, если провайдера в истории нет —
    # тогда вызывающий код останется на заявленной конверсии.
    def success_rate_for(provider_id)
      counts = counts_for(provider_id)
      return nil if counts[:total].zero?

      counts[:approved].to_f / counts[:total]
    end

    # Нижняя граница Вильсона: честная оценка «не хуже чем» при малой выборке.
    def conservative_rate_for(provider_id, confidence = 0.95)
      counts = counts_for(provider_id)
      return nil if counts[:total].zero?

      Statistics.wilson_lower_bound(counts[:approved], counts[:total], confidence)
    end

    def median_latency_for(provider_id, status = nil)
      values = @by_provider.fetch(provider_id, [])
                           .select { |r| status.nil? || r[:status] == status }
                           .filter_map { |r| r[:latency_sec] }
                           .sort
      return nil if values.empty?

      middle = values.size / 2
      values.size.odd? ? values[middle] : ((values[middle - 1] + values[middle]) / 2.0)
    end

    # Фактические доли по истории — с ними сравнивается целевое распределение.
    def observed_shares
      total = @rows.size
      return {} if total.zero?

      @by_provider.transform_values { |rows| rows.size.to_f / total }
    end

    def observed_volume_shares
      total = @rows.sum { |r| r[:amount].to_major.to_f }
      return {} if total <= 0

      @by_provider.transform_values do |rows|
        rows.sum { |r| r[:amount].to_major.to_f } / total
      end
    end

    # Сводка, которую можно положить в отчёт и показать на защите.
    def summary(confidence = 0.95)
      shares = observed_shares
      volume = observed_volume_shares
      providers.to_h do |id|
        counts = counts_for(id)
        [id, {
          "operations" => counts[:total],
          "approved" => counts[:approved],
          "rejected" => counts[:rejected],
          "expired" => counts[:expired],
          "success_rate" => success_rate_for(id)&.round(4),
          "success_rate_lower_bound" => conservative_rate_for(id, confidence)&.round(4),
          "count_share_pct" => ((shares[id] || 0) * 100).round(2),
          "volume_share_pct" => ((volume[id] || 0) * 100).round(2),
          "median_latency_sec" => median_latency_for(id),
          "median_latency_approved_sec" => median_latency_for(id, SUCCESS)
        }.compact]
      end
    end
  end
end
