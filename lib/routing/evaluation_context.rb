# frozen_string_literal: true

module Routing
  # Всё, что нужно правилу, чтобы вынести решение по одной паре
  # «заявка + провайдер». Отдельный объект вместо длинного списка аргументов:
  # добавить новое правило, которому нужны, скажем, история и часы,
  # можно не трогая сигнатуры всех остальных.
  EvaluationContext = Struct.new(
    :operation, :provider, :state, :fleet, :at, :config, :history, :attempt_no, :excluded, :eligible_ids, :time_known,
    keyword_init: true
  ) do
    def id = provider.id

    def excluded?(provider_id) = Array(excluded).include?(provider_id)

    # Пул, на который пересчитываются цели по долям. nil означает
    # «считать по всем», что нужно для аналитики вне контекста заявки.
    def pool = eligible_ids

    # Известно ли настоящее время заявки. Если во входных данных нет
    # отметок, часы идут виртуально, и правила, опирающиеся на время,
    # начинают срабатывать на ровном месте.
    def time_known? = time_known.nil? ? true : !!time_known
  end
end
