# frozen_string_literal: true

module Routing
  # Заявка на выплату — то, что мы маршрутизируем.
  class Operation
    attr_reader :id, :amount, :bank, :bank_key, :currency, :created_at,
                :merchant_id, :payment_method, :country, :raw, :index

    def self.from_record(record, index:, bank_aliases: {})
      new(
        id: record.string("operation_id") || "op_#{index + 1}",
        amount: record.money("amount", default: 0),
        bank: record.string("bank"),
        currency: (record.string("currency") || "RUB").upcase,
        created_at: record.time("created_at"),
        merchant_id: record.string("merchant_id"),
        payment_method: record.string("payment_method"),
        country: record.string("country"),
        index: index,
        bank_aliases: bank_aliases,
        raw: record.raw
      )
    end

    def initialize(id:, amount:, index:, bank: nil, currency: "RUB", created_at: nil, merchant_id: nil,
                   payment_method: nil, country: nil, bank_aliases: {}, raw: {})
      @id = id
      @amount = Money.from_major(amount)
      @bank = bank
      @bank_key = Bank.normalize(bank, bank_aliases)
      @currency = currency
      @created_at = created_at
      @merchant_id = merchant_id
      @payment_method = payment_method
      @country = country
      @index = index
      @raw = raw
    end

    def to_h
      {
        operation_id: id,
        amount: amount.as_json,
        currency: currency,
        bank: bank,
        merchant_id: merchant_id,
        payment_method: payment_method,
        created_at: created_at&.iso8601
      }.compact
    end
  end
end
