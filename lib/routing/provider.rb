# frozen_string_literal: true

module Routing
  # Неизменяемая часть провайдера: то, что задано соглашением и настройками.
  # Всё, что меняется по ходу прогона (оборот, счётчики, реквизиты),
  # живёт отдельно в ProviderState — чтобы откат неудачной попытки был
  # честной операцией над состоянием, а не правкой конфигурации.
  class Provider
    attr_reader :id, :name, :status, :traffic_percentage, :volume_share_pct, :priority,
                :limit_amount_min, :limit_amount_max, :daily_amount_limit,
                :daily_turnover_min, :daily_turnover_max,
                :in_progress_count_limit, :in_progress_amount_limit,
                :banks, :exclude_banks, :banks_are_blacklist, :conversion_24h,
                :banks_literal, :exclude_banks_literal,
                :provider_margin_pct, :merchant_margin_pct, :allow_negative_agreement,
                :requests_per_minute_limit, :currencies, :avg_latency_sec,
                :initial_requisites, :initial_daily_amount,
                :initial_in_progress_count, :initial_in_progress_amount,
                :self_provider, :raw, :unknown_fields

    def self.from_record(record, defaults: {}, bank_aliases: {}, self_provider_ids: [])
      id = record.string("id") || record.string("name")
      raise DataError.new("у провайдера нет ни id, ни name", source: record.source) if id.nil? || id.empty?

      new(
        id: id,
        name: record.string("name", default: id),
        status: (record.string("status", default: "active")).downcase,
        traffic_percentage: record.percent("traffic_percentage", default: defaults[:traffic_percentage]),
        volume_share_pct: record.percent("volume_share_pct", default: nil),
        priority: record.integer("priority", default: nil),
        limit_amount_min: record.money("limit_amount_min", default: nil),
        limit_amount_max: record.money("limit_amount_max", default: nil),
        daily_amount_limit: record.money("daily_amount_limit", default: nil),
        daily_turnover_min: record.money("daily_turnover_min", default: nil),
        daily_turnover_max: record.money("daily_turnover_max", default: nil),
        in_progress_count_limit: record.integer("in_progress_count_limit", default: nil),
        in_progress_amount_limit: record.money("in_progress_amount_limit", default: nil),
        banks: Bank.normalize_all(record.list("banks"), bank_aliases),
        exclude_banks: Bank.normalize_all(record.list("exclude_banks"), bank_aliases),
        # Те же списки без приведения к общему виду: правило допуска умеет
        # сравнивать написания дословно, как это делает скрипт организаторов.
        banks_literal: record.list("banks").map(&:to_s),
        exclude_banks_literal: record.list("exclude_banks").map(&:to_s),
        banks_are_blacklist: blacklist_mode?(record),
        conversion_24h: record.ratio("conversion_24h", default: defaults[:conversion_24h]),
        provider_margin_pct: record.percent("provider_margin_pct", default: 0.0),
        merchant_margin_pct: record.percent("merchant_margin_pct", default: nil),
        allow_negative_agreement: record.boolean("allow_negative_agreement", default: false),
        requests_per_minute_limit: record.integer("requests_per_minute_limit", default: nil),
        currencies: record.list("currency").map { |c| c.upcase },
        avg_latency_sec: record.float("avg_latency_sec", default: defaults[:avg_latency_sec]),
        initial_requisites: record.integer("available_requisites", default: nil),
        initial_daily_amount: record.money("daily_approved_amount", default: 0),
        initial_in_progress_count: record.integer("in_progress_count", default: 0),
        initial_in_progress_amount: record.money("in_progress_amount", default: 0),
        self_provider: record.boolean("is_self", default: self_provider_ids.include?(id)),
        raw: record.raw,
        unknown_fields: record.unrecognized_keys
      )
    end

    # В данных кейса `exclude_banks` — не список, а флаг: он говорит, как
    # читать поле `banks`. false — это белый список, true — чёрный.
    # В тексте ТЗ то же поле описано как отдельный список банков, поэтому
    # поддерживаем оба прочтения: тип значения и определяет смысл.
    def self.blacklist_mode?(record)
      value = record.raw_value("exclude_banks")
      return true if value == true
      return %w[true yes 1 да].include?(value.strip.downcase) if value.is_a?(String)
    
      false
    end

    def initialize(**attrs)
      attrs.each { |key, value| instance_variable_set(:"@#{key}", value) }
      @banks ||= []
      @banks_are_blacklist = !!@banks_are_blacklist
      @exclude_banks ||= []
      @banks_literal ||= @banks
      @exclude_banks_literal ||= @exclude_banks
      @currencies ||= []
      @raw ||= {}
      @unknown_fields ||= []
      freeze
    end

    def active? = status == "active"

    # Провайдер последней надежды: используется, когда внешний пул пуст.
    def self_provider? = !!@self_provider

    # Эффективная маржа мерчанта. Если в данных её нет, считаем ограничение
    # по марже неприменимым, а не нарушенным — иначе один недостающий столбец
    # выключит всех провайдеров разом.
    def margin_defined? = !merchant_margin_pct.nil?

    def margin_gap = margin_defined? ? merchant_margin_pct - provider_margin_pct : nil

    def accepts_currency?(currency)
      currencies.empty? || currencies.include?(currency.to_s.upcase)
    end

    def to_h
      {
        id: id, name: name, status: status,
        traffic_percentage: traffic_percentage, volume_share_pct: volume_share_pct,
        priority: priority, conversion_24h: conversion_24h,
        limit_amount_min: limit_amount_min&.as_json, limit_amount_max: limit_amount_max&.as_json,
        daily_amount_limit: daily_amount_limit&.as_json,
        daily_turnover_min: daily_turnover_min&.as_json,
        in_progress_count_limit: in_progress_count_limit,
        in_progress_amount_limit: in_progress_amount_limit&.as_json,
        requests_per_minute_limit: requests_per_minute_limit,
        provider_margin_pct: provider_margin_pct, merchant_margin_pct: merchant_margin_pct,
        banks: banks, exclude_banks: exclude_banks, banks_are_blacklist: banks_are_blacklist,
        is_self: self_provider?
      }.compact
    end
  end
end
