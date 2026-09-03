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
      utilization_alert_pct: 80.0
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

    def render
      View.new(decisions: @decisions, report: @report, options: @options).render("layout")
    end

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

      STATUS_WORDS = {
        good: "в норме",
        warn: "внимание",
        crit: "критично"
      }.freeze

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
      def nice_domain(values, minimum: 10.0)
        top = Array(values).compact.map { |v| v.to_f.abs }.max.to_f
        top = minimum if top < minimum
        step = 10.0**Math.log10(top).floor
        step /= 2 if top / step <= 2
        (top / step).ceil * step
      end

      def ticks(domain, count = 4)
        (0..count).map { |i| (domain.to_f * i / count).round(2) }
      end

      # --- статусы (цвет всегда в паре со словом) ------------------------------

      def utilization_status(value)
        alert = @options[:utilization_alert_pct].to_f
        return :crit if value.to_f >= 95.0
        return :crit if value.to_f >= alert
        return :warn if value.to_f >= alert * 0.75

        :good
      end

      def deviation_status(value)
        limit = @options[:drift_pct].to_f
        return :crit if value.to_f.abs >= limit * 2
        return :warn if value.to_f.abs >= limit

        :good
      end

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

      def priority_status(priority)
        { "high" => :crit, "medium" => :warn, "low" => :good }.fetch(priority.to_s, :good)
      end

      def priority_label(priority)
        { "high" => "высокий", "medium" => "средний", "low" => "низкий" }
          .fetch(priority.to_s, priority.to_s)
      end

      def severity_status(severity)
        { "error" => :crit, "warning" => :warn, "info" => :good }.fetch(severity.to_s, :good)
      end

      def severity_label(severity)
        { "error" => "ошибка", "warning" => "предупреждение", "info" => "замечание" }
          .fetch(severity.to_s, severity.to_s)
      end

      def status_word(status) = STATUS_WORDS.fetch(status, "")

      def verdict_status(verdict)
        verdict.to_s.start_with?("достижима") ? :good : :crit
      end

      # --- производные показатели ----------------------------------------------

      def total_operations = section("total_operations") || @decisions.size

      def approval_rate_pct
        rate = section("outcomes", "approval_rate")
        return nil if rate.nil?

        rate.to_f * 100.0
      end

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
