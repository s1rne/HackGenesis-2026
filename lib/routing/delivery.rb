# frozen_string_literal: true

module Routing
  # Сдача результата.
  #
  # Отдельный объект, а не часть CLI, по простой причине: требования к
  # сдаваемым файлам заданы организаторами и не зависят от того, как их
  # собрали. Имена файлов, их место, структура и обязательные поля — это
  # контракт, и он должен быть описан в одном месте, где его можно прочитать
  # и проверить тестом.
  #
  # Имена зашиты намеренно: опечатка в имени файла стоит сорока баллов
  # независимо от качества всего остального.
  module Delivery
    QUEUE = "data/operations_queue_test.json"
    DECISIONS = "routing_decisions_test.json"
    REPORT = "routing_report_test.json"

    REQUIRED_REPORT_KEYS = %w[period total_operations distribution skip_reasons
                              projected_daily_utilization recommendations].freeze
    ALLOWED_RESULTS = %w[approved rejected expired].freeze
    ALLOWED_DECISIONS = %w[selected skipped].freeze

    module_function

    # Условия, при которых выгрузку нельзя считать пригодной. Проверяются на
    # каждом прогоне, а не только при сдаче: автопроверка организаторов
    # завершается с ошибкой на файле, где у заявки нет провайдера, и молча
    # отдать такой файл — худшее, что может сделать инструмент.
    def integrity_problems(decisions)
      problems = []

      unrouted = decisions.select { |decision| decision.selected_provider.nil? }
      unless unrouted.empty?
        shown = unrouted.first(5).map { |decision| decision.operation.id }.join(", ")
        problems << "без провайдера осталось заявок: #{unrouted.size} " \
                    "(#{shown}#{unrouted.size > 5 ? '…' : ''})"
      end

      duplicates = decisions.map { |decision| decision.operation.id }
                            .tally.select { |_, count| count > 1 }.keys
      problems << "повторяющиеся operation_id: #{duplicates.join(', ')}" unless duplicates.empty?

      bad = decisions.reject { |decision| ALLOWED_RESULTS.include?(decision.simulated_result) }
      unless bad.empty?
        problems << "недопустимый simulated_result у заявок: " \
                    "#{bad.map { |decision| decision.operation.id }.join(', ')}"
      end

      problems
    end

    # Проверки ровно на то, за что снимают баллы: имя, место, структура,
    # покрытие всех заявок и обязательные поля в обоих файлах.
    # Возвращает список пар «пройдено, что проверяли».
    def checks(operations, decisions, decisions_path: DECISIONS, report_path: REPORT)
      decisions_payload = read_json(decisions_path)
      report_payload = read_json(report_path)
      ids = operations.map(&:id)
      covered = decisions_payload.is_a?(Array) ? decisions_payload.map { |d| d["operation_id"] } : []

      [
        [File.file?(decisions_path), "#{decisions_path} лежит в корне репозитория"],
        [File.file?(report_path), "#{report_path} лежит в корне репозитория"],
        [decisions_payload.is_a?(Array), "решения — массив в корне JSON"],
        [(ids - covered).empty?, "покрыты все #{ids.size} заявок из очереди"],
        [(covered - ids).empty?, "нет лишних operation_id"],
        [decisions.all?(&:selected_provider), "у каждой заявки есть selected_provider"],
        [attempts_well_formed?(decisions_payload), "у всех attempts есть provider, decision и reason"],
        [decisions.all? { |d| ALLOWED_RESULTS.include?(d.simulated_result) },
         "simulated_result только #{ALLOWED_RESULTS.join(' / ')}"],
        [decisions.all? { |d| d.latency_sec.is_a?(Integer) && d.latency_sec >= 0 },
         "latency_sec — целое неотрицательное"],
        [report_payload.is_a?(Hash) && REQUIRED_REPORT_KEYS.all? { |key| report_payload.key?(key) },
         "в отчёте есть все обязательные разделы"],
        [report_payload.is_a?(Hash) && report_payload["total_operations"] == ids.size,
         "total_operations в отчёте совпадает с числом заявок"]
      ]
    end

    def attempts_well_formed?(payload)
      return false unless payload.is_a?(Array)

      payload.all? do |decision|
        attempts = decision["attempts"]
        attempts.is_a?(Array) && !attempts.empty? && attempts.all? do |attempt|
          %w[provider decision reason].all? { |key| attempt[key].to_s != "" } &&
            ALLOWED_DECISIONS.include?(attempt["decision"])
        end
      end
    end

    def read_json(path)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end
  end
end
