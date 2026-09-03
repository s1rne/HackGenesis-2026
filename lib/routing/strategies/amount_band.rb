# frozen_string_literal: true

module Routing
  module Strategies
    # Стратегия 4: маршрутизация по диапазону суммы чека.
    #
    # Важная тонкость: limit_amount_min/max — это жёсткий допуск, он лишь
    # отсекает. Здесь диапазон работает иначе — он влияет на выбор МЕЖДУ
    # уже допущенными провайдерами.
    #
    # Работает в двух режимах. Если в конфигурации описаны полосы
    # (`bands`), сумма попадает в полосу и провайдеры из `prefer` получают
    # предпочтение. Если полос нет, предпочтение выводится из самих данных:
    # чем уже собственный диапазон провайдера вокруг этой суммы, тем более он
    # под неё специализирован — универсал с диапазоном 500–1 000 000 уступит
    # тому, кто настроен на 50 000–100 000.
    class AmountBand < Base
      NEUTRAL = 0.5

      def raw_score(context)
        bands.empty? ? specialization_score(context) : band_score(context)
      end

      def explain(context)
        amount = context.operation.amount
        if bands.empty?
          width = range_width(context.provider)
          return "диапазон провайдера не задан, предпочтение по сумме не считается" if width.nil?

          return "сумма #{amount} внутри диапазона #{range_label(context.provider)} " \
                 "(ширина #{width.round}, чем уже — тем выше специализация)"
        end

        band = matching_band(amount)
        return "сумма #{amount} не попала ни в одну настроенную полосу" if band.nil?

        preferred = Array(band["prefer"])
        verdict = preferred.include?(context.provider.id) ? "предпочтителен" : "не в списке предпочтения"
        "сумма #{amount} в полосе #{band_label(band)} -> #{verdict} (#{preferred.join(', ')})"
      end

      private

      def bands = Array(setting("bands", []))

      def band_score(context)
        band = matching_band(context.operation.amount)
        return NEUTRAL if band.nil?

        preferred = Array(band["prefer"])
        return NEUTRAL if preferred.empty?

        if preferred.include?(context.provider.id)
          weight = band["preference"] || 1.0
          NEUTRAL + (weight.to_f / 2.0)
        else
          NEUTRAL - (band.fetch("penalty", 0.5).to_f / 2.0)
        end
      end

      def matching_band(amount)
        value = amount.to_major.to_f
        bands.find do |band|
          min = band["min"] ? Money.from_major(band["min"]).to_major.to_f : -Float::INFINITY
          max = band["max"] ? Money.from_major(band["max"]).to_major.to_f : Float::INFINITY
          value >= min && value <= max
        end
      end

      def band_label(band) = "#{band['min'] || '-'}..#{band['max'] || '+'}"

      # Чем уже диапазон, тем выше специализация. Логарифм — чтобы разница
      # между 50 000 и 100 000 не терялась на фоне провайдера с диапазоном в миллион.
      def specialization_score(context)
        width = range_width(context.provider)
        return nil if width.nil?

        -Math.log10([width, 1.0].max)
      end

      def range_width(provider)
        min = provider.limit_amount_min&.to_major&.to_f
        max = provider.limit_amount_max&.to_major&.to_f
        return nil if min.nil? && max.nil?

        (max || (min.to_f * 100)) - (min || 0.0)
      end

      def range_label(provider)
        "#{provider.limit_amount_min || '-'}..#{provider.limit_amount_max || '+'}"
      end
    end
  end
end
