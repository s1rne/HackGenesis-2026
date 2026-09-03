# frozen_string_literal: true

module Routing
  module Constraints
    Violation = Struct.new(:reason, :details, keyword_init: true) do
      def to_h = { reason: reason, details: details }.compact
    end

    # Жёсткое ограничение отвечает ровно на один вопрос: «можно ли вообще
    # отправить эту заявку этому провайдеру». Оно не сравнивает провайдеров
    # между собой и не имеет веса — только допуск или отказ с причиной.
    #
    # Новое ограничение добавляется наследованием и одной строкой в реестре;
    # ни каскад, ни скоринг об этом знать не обязаны.
    class Base
      class << self
        # Анонимный подкласс (Class.new(Base)) имени не имеет. Такой класс
        # не может быть адресован из конфигурации, поэтому в реестр он не
        # попадает — но и падать в момент определения не должен.
        def id = name && name.split("::").last.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase

        # Зависит ли правило от текущего состояния провайдера (оборот,
        # заявки в работе, реквизиты, интенсивность) или только от
        # неизменной конфигурации. Структурные правила определяют, какие
        # цели достижимы в принципе, а какие — нет ни при какой политике.
        def stateful? = false

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

      # Возвращает nil, если провайдер допущен, иначе Violation.
      def check(_context)
        raise NotImplementedError, "#{self.class}#check не реализован"
      end

      # Ограничение может быть неприменимо к данным (поля просто нет).
      # Это не нарушение: отсутствующий лимит — это отсутствие лимита.
      def skip = nil

      def violation(reason, details = nil) = Violation.new(reason: reason, details: details)

      private

      def setting(key, default = nil) = @settings.fetch(key.to_s, default)
    end

    # Реестр ограничений: правило регистрируется самим фактом наследования,
    # а конфигурация решает, какие из зарегистрированных включены и в каком порядке.
    module Registry
      @classes = {}

      class << self
        attr_reader :classes

        def register(klass) = @classes[klass.id] = klass

        def build(config)
          order = config.enabled_constraint_ids
          unknown = order - @classes.keys
          unless unknown.empty?
            raise ConfigError, "в hard_constraints указаны неизвестные правила: #{unknown.join(', ')}"
          end

          order.map { |id| @classes.fetch(id).new(config.constraint(id)) }
        end

        def known_ids = @classes.keys.sort
      end
    end
  end
end
