# frozen_string_literal: true

module Routing
  module Strategies
    # Мягкая цель отвечает на другой вопрос, чем жёсткое ограничение:
    # не «можно ли», а «кого предпочесть» среди тех, кому уже можно.
    #
    # Каждая цель возвращает «сырую» величину предпочтения — в своих единицах:
    # рубли недобора оборота, доля дефицита, конверсия, номер приоритета.
    # Сравнивать их между собой напрямую нельзя, поэтому нормализацией
    # в диапазон 0..1 занимается Scorer, а цель остаётся честной к своей природе.
    #
    # Новая цель — это новый класс с методами raw_score и explain, плюс строка
    # в конфигурации. Ни каскад, ни отчёт менять не нужно.
    class Base
      class << self
        # Анонимный подкласс (Class.new(Base)) имени не имеет. Такой класс
        # не может быть адресован из конфигурации, поэтому в реестр он не
        # попадает — но и падать в момент определения не должен.
        def id = name && name.split("::").last.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase

        def inherited(subclass)
          super
          Registry.register(subclass) if subclass.id
        end
      end

      attr_reader :settings

      def initialize(settings = {})
        @settings = settings || {}
      end

      def id = self.class.id
      def weight = setting("weight", 1.0).to_f
      def tier = setting("tier", 2).to_i

      # Сырая величина предпочтения; больше — лучше. nil означает
      # «цель неприменима к этому провайдеру» — он получит нейтральную оценку.
      def raw_score(_context)
        raise NotImplementedError, "#{self.class}#raw_score не реализован"
      end

      # Короткая человеческая расшифровка того, что цель увидела.
      # Она попадает в attempts, поэтому пишется для чтения, а не для парсинга.
      def explain(_context) = nil

      # Причина выбора, которой цель представляется в объяснении.
      def selection_reason = Reasons.for_strategy(id)

      protected

      def setting(key, default = nil)
        value = @settings[key.to_s]
        value.nil? ? default : value
      end

      def pct(value) = (value.to_f * 100).round(1)
    end

    # Реестр целей. Как и у ограничений, регистрация происходит при наследовании,
    # а состав и веса задаёт конфигурация.
    module Registry
      @classes = {}

      class << self
        attr_reader :classes

        def register(klass) = @classes[klass.id] = klass

        def build(config)
          ids = config.enabled_strategy_ids
          unknown = ids - @classes.keys
          raise ConfigError, "в strategies указаны неизвестные цели: #{unknown.join(', ')}" unless unknown.empty?

          ids.map { |id| @classes.fetch(id).new(config.strategy(id)) }
        end

        def known_ids = @classes.keys.sort
      end
    end
  end
end
