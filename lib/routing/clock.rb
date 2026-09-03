# frozen_string_literal: true

module Routing
  # Часы прогона.
  #
  # Ограничение по интенсивности имеет смысл только во времени, а время в
  # заявках может быть, а может и не быть. Если `created_at` есть — идём по
  # нему; если нет — двигаем виртуальные часы на шаг вперёд. Так лимит
  # «7 заявок в минуту» работает в обоих случаях, а поведение остаётся
  # воспроизводимым.
  class Clock
    attr_reader :started_at, :now

    # Условная отметка на случай, когда времени нет ни в снимке провайдеров,
    # ни в заявках. Раньше здесь стоял Time.now, и это была скрытая
    # невоспроизводимость: правила, зависящие от времени суток, давали разный
    # результат в зависимости от того, когда запустили прогон. Фиксированная
    # отметка делает результат одинаковым всегда, а о самом факте её
    # применения загрузчик пишет замечание.
    FALLBACK_ANCHOR = Time.utc(2000, 1, 1).freeze

    attr_reader :anchored_by_fallback

    def initialize(started_at: nil, step_sec: 1.0)
      @started_at = started_at
      @step = step_sec.to_f
      @now = started_at&.to_f
      @anchored_by_fallback = false
    end

    def advance_to(operation)
      stamp = operation.created_at&.to_f
      if @started_at.nil?
        if stamp
          @started_at = Time.at(stamp)
        else
          @started_at = FALLBACK_ANCHOR
          @anchored_by_fallback = true
        end
      end
      @now = if stamp
               # Время не идёт назад: если очередь пришла неотсортированной,
               # берём максимум, иначе скользящее окно начнёт «забывать» заявки.
               @now.nil? ? stamp : [@now, stamp].max
             else
               (@now || @started_at.to_f) + @step
             end
    end

    def to_time = Time.at(@now || Time.now.to_f)
  end
end
