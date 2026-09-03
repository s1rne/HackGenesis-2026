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

    def initialize(started_at: nil, step_sec: 1.0)
      @started_at = started_at
      @step = step_sec.to_f
      @now = started_at&.to_f
    end

    def advance_to(operation)
      stamp = operation.created_at&.to_f
      @started_at ||= stamp ? Time.at(stamp) : Time.now
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
