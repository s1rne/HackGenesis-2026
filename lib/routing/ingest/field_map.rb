# frozen_string_literal: true

module Routing
  module Ingest
    # Карта «каноническое имя поля -> как это поле могут назвать во входных данных».
    #
    # Мы не знаем заранее, придут ли данные с ключом `limit_amount_max`,
    # `limitAmountMax`, `max_amount` или `amount_max`. Вместо того чтобы
    # переписывать модель под каждый новый файл, мы описываем синонимы один раз
    # здесь и расширяем их из конфигурации (`field_aliases` в routing.yml).
    class FieldMap
      # Ключи сравниваются в нормализованном виде: строчные буквы, любые
      # разделители схлопнуты в подчёркивание. Поэтому "Limit Amount Max",
      # "limitAmountMax" и "limit-amount-max" — одно и то же поле.
      def self.normalize_key(key)
        key.to_s
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .downcase
           .gsub(/[^a-zа-яё\d]+/, "_")
           .gsub(/\A_+|_+\z/, "")
      end

      DEFAULT_ALIASES = {
        # --- провайдер ---
        "id" => %w[id payment_system provider_id code slug key],
        "name" => %w[name title provider_name provider payment_system label],
        "status" => %w[status state provider_status enabled active],
        "traffic_percentage" => %w[traffic_percentage traffic_pct traffic_share count_share_pct
                                   target_share_pct share_pct weight],
        "volume_share_pct" => %w[volume_share_pct volume_share volume_pct amount_share_pct turnover_share_pct],
        "priority" => %w[priority cascade_priority order rank position],
        "limit_amount_min" => %w[limit_amount_min min_amount amount_min limit_min min_check],
        "limit_amount_max" => %w[limit_amount_max max_amount amount_max limit_max max_check],
        "daily_amount_limit" => %w[daily_amount_limit daily_limit daily_max limit_daily_amount
                                   daily_turnover_max daily_amount_max],
        "daily_approved_amount" => %w[daily_approved_amount daily_amount daily_turnover today_amount
                                      approved_amount_today current_daily_amount],
        "in_progress_count_limit" => %w[in_progress_count_limit inprogress_count_limit
                                        concurrent_limit max_in_progress_count],
        "in_progress_count" => %w[in_progress_count inprogress_count concurrent_count current_in_progress_count],
        "in_progress_amount_limit" => %w[in_progress_amount_limit inprogress_amount_limit
                                         max_in_progress_amount],
        "in_progress_amount" => %w[in_progress_amount inprogress_amount current_in_progress_amount],
        "available_requisites" => %w[available_requisites requisites free_requisites terminals
                                     available_terminals requisites_count],
        "banks" => %w[banks allowed_banks bank_list include_banks supported_banks],
        "exclude_banks" => %w[exclude_banks excluded_banks banks_exclude denied_banks blocked_banks],
        "conversion_24h" => %w[conversion_24h conversion conversion_rate cr conversion_rate_24h approval_rate],
        "provider_margin_pct" => %w[provider_margin_pct provider_margin margin_pct provider_fee_pct],
        "merchant_margin_pct" => %w[merchant_margin_pct merchant_margin merchant_fee_pct],
        "allow_negative_agreement" => %w[allow_negative_agreement allow_negative_margin negative_agreement],
        "requests_per_minute_limit" => %w[requests_per_minute_limit rpm_limit rate_limit_per_minute
                                          requests_per_minute max_rpm],
        "daily_turnover_min" => %w[daily_turnover_min min_daily_turnover daily_min_turnover
                                   turnover_commitment_min],
        "daily_turnover_max" => %w[daily_turnover_max max_daily_turnover turnover_commitment_max],
        "currency" => %w[currency currencies ccy],
        "avg_latency_sec" => %w[avg_latency_sec latency_sec avg_latency mean_latency_sec],
        "is_self" => %w[is_self self_provider internal fallback_provider],

        # --- операция ---
        "operation_id" => %w[operation_id id op_id order_id payment_id request_id],
        "amount" => %w[amount sum value total payout_amount],
        "bank" => %w[bank bank_name bank_code target_bank payout_bank],
        "created_at" => %w[created_at created timestamp ts time date requested_at],
        "merchant_id" => %w[merchant_id merchant shop_id client_id],
        "payment_method" => %w[payment_method method type payout_method channel],
        "country" => %w[country country_code region],
        "card_brand" => %w[card_brand brand scheme]
      }.freeze

      attr_reader :table

      def initialize(extra_aliases = {})
        @table = {}
        DEFAULT_ALIASES.each { |canonical, names| register(canonical, names) }
        extra_aliases.each { |canonical, names| register(canonical, Array(names)) }
      end

      def register(canonical, names)
        canonical = canonical.to_s
        (@table[canonical] ||= [])
        ([canonical] + Array(names)).each do |name|
          normalized = self.class.normalize_key(name)
          @table[canonical] << normalized unless @table[canonical].include?(normalized)
        end
      end

      def candidates_for(canonical) = @table.fetch(canonical.to_s, [self.class.normalize_key(canonical)])
    end
  end
end
