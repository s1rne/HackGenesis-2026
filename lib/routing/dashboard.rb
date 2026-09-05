# frozen_string_literal: true

require "erb"
require "json"
require "time"
require "fileutils"
require "optparse"

require_relative "reasons"

module Routing
  # Генератор статического дашборда по результатам прогона.
  #
  # На вход — два файла, которые и так уезжают в корень репозитория:
  # routing_decisions.json (решение по каждой заявке) и routing_report.json
  # (агрегированная аналитика). На выход — один самодостаточный HTML: стили и
  # скрипты внутри файла, ни одного внешнего запроса. Такой файл открывается
  # с диска на любом ноутбуке и переживает отсутствие сети на защите.
  #
  # Шаблоны лежат в views/ и рендерятся ERB из стандартной библиотеки.
  # Ни один необязательный раздел отчёта не является обязательным для
  # дашборда: нет секции — раздел просто не рисуется.
  class Dashboard
    VIEWS = File.expand_path("views", __dir__)

    DEFAULTS = {
      decisions: "routing_decisions.json",
      report: "routing_report.json",
      out: "out/dashboard.html",
      drift_pct: 10.0,
      utilization_alert_pct: 80.0,
      conversion_alert: 0.6
    }.freeze

    def initialize(decisions:, report:, options: {})
      @decisions = Array(decisions)
      @report = report.is_a?(Hash) ? report : {}
      @options = DEFAULTS.merge(options)
    end

    # Читает входные файлы и возвращает готовый дашборд.
    def self.from_files(decisions_path:, report_path:, options: {})
      new(decisions: read_json(decisions_path, []),
          report: read_json(report_path, {}),
          options: options)
    end

    def self.read_json(path, fallback)
      raise Errno::ENOENT, path unless File.file?(path)

      content = File.read(path, encoding: "UTF-8")
      return fallback if content.strip.empty?

      JSON.parse(content)
    rescue JSON::ParserError => e
      raise ArgumentError, "не разобран JSON #{path}: #{e.message}"
    end

    def render = view.render("layout")

    # Слой представления доступен снаружи: вердикт первого экрана — это
    # суждение, а не вёрстка, и проверять его надо отдельно от HTML.
    def view = View.new(decisions: @decisions, report: @report, options: @options)

    def write(path)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir) unless dir.empty? || File.directory?(dir)
      File.write(path, render, encoding: "UTF-8")
      path
    end

    # Контекст рендеринга: данные плюс форматирование.
    #
    # Всё, что приходит из данных, проходит через #h — в полях есть кавычки,
    # русский текст и произвольные строки из чужих файлов.
    class View
      NBSP = " "

      attr_reader :report, :decisions, :options

      def initialize(decisions:, report:, options:)
        @decisions = decisions
        @report = report
        @options = options
      end

      def render(name)
        path = ["#{name}.html.erb", "#{name}.erb"]
               .map { |file| File.join(VIEWS, file) }
               .find { |candidate| File.file?(candidate) }
        raise Errno::ENOENT, File.join(VIEWS, "#{name}.html.erb") if path.nil?

        ERB.new(File.read(path, encoding: "UTF-8"), trim_mode: "-").result(binding)
      end

      # --- доступ к разделам ---------------------------------------------------

      def section(*keys)
        keys.reduce(@report) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
      end

      def present?(*keys)
        value = section(*keys)
        !(value.nil? || (value.respond_to?(:empty?) && value.empty?))
      end

      # --- экранирование и форматирование --------------------------------------

      def h(value) = ERB::Util.html_escape(value.to_s)

      def blank?(value) = value.nil? || (value.respond_to?(:empty?) && value.empty?)

      # Число с разделителем разрядов. Разделитель — неразрывный пробел,
      # чтобы сумма не переносилась по строке посреди разрядов.
      def num(value, digits = 0)
        return "—" if value.nil?

        rounded = value.to_f.round(digits)
        whole, frac = format("%.#{digits}f", rounded).split(".")
        sign = whole.start_with?("-") ? "-" : ""
        grouped = whole.delete("-").reverse.scan(/\d{1,3}/).join(NBSP).reverse
        [sign, grouped, frac ? ",#{frac}" : ""].join
      end

      def money(value)
        return "—" if value.nil?

        "#{num(value)}#{NBSP}₽"
      end

      def pct(value, digits = 1)
        return "—" if value.nil?

        "#{num(value, digits)}%"
      end

      def signed(value, digits = 1, suffix = "")
        return "—" if value.nil?

        sign = value.to_f.round(digits) > 0 ? "+" : ""
        "#{sign}#{num(value, digits)}#{suffix}"
      end

      def seconds(value)
        return "—" if value.nil?

        "#{num(value, value.to_f == value.to_i ? 0 : 1)}#{NBSP}с"
      end

      # --- каталог причин ------------------------------------------------------

      # Человеческая формулировка машинного кода. Перевод не дублируется здесь:
      # единственный источник — каталог Routing::Reasons.
      def reason_text(code) = Reasons.text(code)

      def reason_category(code)
        case Reasons.category(code)
        when :hard then "жёсткое ограничение"
        when :soft then "выбор среди допустимых"
        when :attempt then "результат попытки"
        when :selection then "причина выбора"
        else "прочее"
        end
      end

      # --- геометрия диаграмм --------------------------------------------------

      def scale(value, domain)
        return 0.0 if domain.nil? || domain.to_f <= 0 || value.nil?

        [[value.to_f / domain.to_f * 100.0, 0.0].max, 100.0].min.round(3)
      end

      # Верхняя граница шкалы: округляем вверх до «круглого» числа, чтобы
      # засечки сетки читались, а самый длинный столбик не упирался в край.
      # --- статусы (цвет всегда в паре со словом) ------------------------------

      def outcome_status(outcome)
        case outcome
        when "approved" then :good
        when "rejected" then :crit
        else :warn
        end
      end

      def outcome_label(outcome)
        { "approved" => "одобрено", "rejected" => "отказ", "expired" => "истекло" }
          .fetch(outcome.to_s, outcome.to_s)
      end

      def severity_status(severity)
        { "error" => :crit, "warning" => :warn, "info" => :good }.fetch(severity.to_s, :good)
      end

      def severity_label(severity)
        { "error" => "ошибка", "warning" => "предупреждение", "info" => "замечание" }
          .fetch(severity.to_s, severity.to_s)
      end

      def verdict_status(verdict)
        verdict.to_s.start_with?("достижима") ? :good : :crit
      end

      # --- производные показатели ----------------------------------------------

      # --- вердикт прогона -----------------------------------------------------

      Finding = Struct.new(:severity, :title, :detail, :action, keyword_init: true)

      # Первое, что должен узнать человек, открывший отчёт: всё ли в порядке,
      # а если нет — что именно и что с этим делать. Ниже по странице есть
      # всё то же самое в разрезах, но разрезы отвечают на вопрос «сколько»,
      # а не на вопрос «надо ли вмешиваться».
      #
      # Порядок фиксированный: сначала то, что ломает выгрузку, потом то, что
      # стоит денег, потом то, что стоит внимания. Внутри группы — по величине.
      def findings
        @findings ||= [
          finding_unrouted, finding_data_errors, finding_capacity,
          finding_limits, finding_deviation, finding_volume_deviation, finding_conversion
        ].compact
      end

      def verdict_level
        return "error" if findings.any? { |item| item.severity == "error" }
        return "warn" if findings.any? { |item| item.severity == "warn" }

        "ok"
      end

      def verdict_headline
        case verdict_level
        when "error" then "Требует вмешательства"
        when "warn" then "Работает, есть на что посмотреть"
        else "В норме"
        end
      end

      private

      def finding_unrouted
        without = @decisions.count { |item| blank?(item["selected_provider"]) }
        return nil if without.zero?

        Finding.new(severity: "error",
                    title: "#{without} #{plural(without, 'заявка', 'заявки', 'заявок')} без провайдера",
                    detail: "маршрут не найден даже на собственном гейте",
                    action: "разобрать командой bin/route explain по идентификатору заявки")
      end

      def finding_data_errors
        counts = section("data_quality", "counts") || {}
        errors = counts["error"].to_i
        warnings = counts["warning"].to_i
        return nil if errors.zero? && warnings.zero?

        Finding.new(severity: errors.positive? ? "error" : "warn",
                    title: errors.positive? ? "#{errors} #{plural(errors, 'ошибка', 'ошибки', 'ошибок')} во входных данных" : "#{warnings} #{plural(warnings, 'замечание', 'замечания', 'замечаний')} к входным данным",
                    detail: "часть значений пришлось достроить по умолчанию",
                    action: "разбор — в «Входные данные» внизу страницы")
      end

      def finding_capacity
        alarms = section("capacity_alarms")
        return nil if blank?(alarms)

        providers = (alarms["by_provider"] || {}).keys.join(", ")
        Finding.new(severity: "warn",
                    title: "#{alarms['operations']} из #{alarms['of_total']} заявок ушли на собственный гейт",
                    detail: "у партнёра кончилась ёмкость (#{providers}); это #{money(alarms['amount_diverted'])}, которые он сегодня уже не возьмёт",
                    action: "поднять дневной лимит или перераспределить долю трафика")
      end

      def finding_limits
        rows = section("limits_at_risk")
        return nil if blank?(rows)

        worst = rows.max_by { |row| (row["measures"] || {}).values.map(&:to_f).max || 0.0 }
        value = (worst["measures"] || {}).values.map(&:to_f).max
        Finding.new(severity: "warn",
                    title: "#{worst['provider']} выбрал #{num(value, 1)}% лимита «#{worst['worst']}»",
                    detail: "когда лимит закончится, партнёр выпадет из распределения до конца суток",
                    action: "колонка «Дневной лимит» в таблице партнёров")
      end

      def finding_deviation
        floors = section("target_achievability", "floors")
        actual = (section("distribution") || {}).values.map { |row| row["deviation_pct"].to_f.abs }.max
        return nil if actual.nil?

        minimum = floors && [floors["rounding_pct"], floors["structural_pct"], floors["exact_pct"]].compact.map(&:to_f).max
        if minimum && (actual - minimum).abs < 0.05
          Finding.new(severity: "ok",
                      title: "Распределение на достижимом минимуме",
                      detail: "отклонение #{num(actual, 1)} п.п. при доказанном минимуме #{num(minimum, 1)} п.п.",
                      action: "ближе к целевым долям на этих данных подойти нельзя")
        elsif actual > @options[:drift_pct].to_f
          Finding.new(severity: "warn",
                      title: "Отклонение от целевых долей #{num(actual, 1)} п.п.",
                      detail: minimum ? "достижимый минимум — #{num(minimum, 1)} п.п." : "порог внимания — #{num(@options[:drift_pct], 0)} п.п.",
                      action: "колонка «Δ п.п.» в таблице партнёров")
        end
      end

      # Конверсия ниже порога — сигнал, но только вместе с размером выборки.
      # Один отказ из трёх даёт 33%, и кричать об этом значит приучить
      # к тому, что тревоги можно не читать.
      MIN_ATTEMPTS_FOR_CONVERSION_ALERT = 5

      # Отклонение по объёму считается отдельно от отклонения по количеству:
      # партнёр может получать ровно свою долю заявок и при этом сильно
      # недобирать в рублях — расходятся размеры чеков, а не маршрутизация.
      # Без этой находки вердикт молчал бы о числе, которое плитка ниже
      # называет критичным.
      def finding_volume_deviation
        worst = (section("distribution") || {})
                .map { |id, row| [id, row["volume_deviation_pct"].to_f] }
                .max_by { |_, value| value.abs }
        return nil if worst.nil? || worst.last.abs <= @options[:drift_pct].to_f

        provider, value = worst
        count_deviation = section("distribution", provider, "deviation_pct").to_f
        Finding.new(severity: "warn",
                    title: "#{provider} #{value.negative? ? 'недобирает' : 'перебирает'} по объёму на #{num(value.abs, 1)} п.п.",
                    detail: "по количеству заявок отклонение #{signed(count_deviation, 1, ' п.п.')} — " \
                            "значит, расходятся не маршруты, а размеры чеков",
                    action: "настроить полосы сумм в amount_band; цель по объёму выведена нами, а не задана в данных")
      end

      def finding_conversion
        threshold = @options[:conversion_alert].to_f
        return nil unless threshold.positive?

        weak = providers_in_report.filter_map do |provider|
          row = performance(provider)
          observed = row["observed_conversion"]
          attempts = row["attempts"].to_i
          next unless observed && attempts >= MIN_ATTEMPTS_FOR_CONVERSION_ALERT
          next unless observed.to_f < threshold

          [provider, observed.to_f, attempts, row["declared_conversion"].to_f]
        end
        return nil if weak.empty?

        provider, observed, attempts, declared = weak.min_by { |row| row[1] }
        Finding.new(severity: "warn",
                    title: "У #{provider} принято #{pct(observed * 100, 0)} заявок из #{attempts}",
                    detail: "заявлено #{pct(declared * 100, 0)}; порог внимания — #{pct(threshold * 100, 0)}. " \
                            "Выборка мала, вывод предварительный",
                    action: "сверить conversion_24h в данных партнёра с фактом")
      end

      def plural(count, one, few, many)
        rest10 = count % 10
        rest100 = count % 100
        return many if (11..14).cover?(rest100)
        return one if rest10 == 1
        return few if (2..4).cover?(rest10)

        many
      end

      public

      def total_operations = section("total_operations") || @decisions.size

      def selected_attempt(decision)
        Array(decision["attempts"]).find { |attempt| attempt["decision"] == "selected" }
      end

      # Сколько попыток реально было сделано. В строгой выгрузке блока cascade
      # нет — тогда считаем по попыткам, которые дошли до провайдера.
      def cascade_depth(decision)
        decision.dig("cascade", "attempts_made") ||
          Array(decision["attempts"]).count { |attempt| attempt["decision"] != "skipped" }
      end

      def providers_in_report
        keys = []
        keys.concat(section("distribution")&.keys || [])
        keys.concat(section("projected_daily_utilization")&.keys || [])
        keys.concat(section("provider_performance")&.keys || [])
        keys.uniq
      end

      def performance(provider) = section("provider_performance", provider) || {}

      def generated_at = Time.now.strftime("%d.%m.%Y %H:%M")

      def sources
        [@options[:decisions], @options[:report]].compact
      end
    end

    # Разбор аргументов и запуск. Значения по умолчанию совпадают с раскладкой
    # репозитория, поэтому голый `ruby bin/dashboard` работает без аргументов.
    class CLI
      def initialize(argv)
        @argv = argv
        @options = DEFAULTS.dup
      end

      def run
        parse!
        dashboard = Dashboard.from_files(
          decisions_path: @options[:decisions],
          report_path: @options[:report],
          options: @options
        )
        path = dashboard.write(@options[:out])
        size = File.size(path)
        warn "Дашборд: #{path} (#{(size / 1024.0).round(1)} КиБ)"
        0
      rescue Errno::ENOENT => e
        warn "Не найден файл: #{e.message.sub('No such file or directory - ', '')}"
        warn "Сначала сформируйте данные: ruby bin/route run"
        1
      rescue ArgumentError => e
        warn "Ошибка: #{e.message}"
        1
      end

      private

      def parse!
        OptionParser.new do |opts|
          opts.banner = "Использование: ruby bin/dashboard [опции]"
          opts.on("--decisions PATH", "решения роутинга (#{DEFAULTS[:decisions]})") { |v| @options[:decisions] = v }
          opts.on("--report PATH", "отчёт аналитики (#{DEFAULTS[:report]})") { |v| @options[:report] = v }
          opts.on("--out PATH", "куда положить HTML (#{DEFAULTS[:out]})") { |v| @options[:out] = v }
          opts.on("--drift PCT", Float, "порог подсветки отклонения, п.п. (#{DEFAULTS[:drift_pct]})") do |v|
            @options[:drift_pct] = v
          end
          opts.on("--utilization PCT", Float,
                  "порог подсветки загрузки, % (#{DEFAULTS[:utilization_alert_pct]})") do |v|
            @options[:utilization_alert_pct] = v
          end
          opts.on("-h", "--help", "эта справка") do
            puts opts
            exit 0
          end
        end.parse!(@argv)
      end
    end
  end
end
