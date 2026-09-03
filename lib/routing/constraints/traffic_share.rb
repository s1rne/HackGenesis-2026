# frozen_string_literal: true

module Routing
  module Constraints
    # Провайдер с нулевой целевой долей выведен из распределения.
    #
    # Это не то же самое, что выключенный статус: гейт жив и может принять
    # заявку, но участвовать в штатном распределении не должен. Ровно так в
    # данных кейса описан self-провайдер: доля 0, приоритет 99, пометка
    # «используется только как fallback». Поэтому провайдер последней надежды
    # из-под этого правила выведен — иначе fallback перестал бы существовать.
    class TrafficShare < Base
      def check(context)
        provider = context.provider
        return skip if provider.self_provider?

        share = provider.traffic_percentage
        return skip if share.nil?
        return nil unless share.to_f.zero?

        violation("zero_traffic_share", "traffic_percentage = #{share}, провайдер вне распределения")
      end
    end
  end
end
