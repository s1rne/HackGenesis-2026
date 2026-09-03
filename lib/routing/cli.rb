# frozen_string_literal: true

module Routing
  # Разбор аргументов и запуск команд.
  #
  # Вся логика лежит в библиотеке; здесь только сборка путей, вывод и коды
  # возврата. Ненулевой код возврата означает, что что-то не сошлось, —
  # на это можно опереться в проверках и на демонстрации.
  class CLI
    DEFAULTS = {
      config: "config/routing.yml",
      overlays: "config/provider_overlays.yml",
      providers: "data/providers.json",
      queue: "data/operations_queue_10.json",
      history: "data/operations_history.csv",
      decisions: "routing_decisions.json",
      report: "routing_report.json",
      profile: nil,
      strict: false,
      quiet: false
    }.freeze

    COMMANDS = %w[plan decisions report run compare validate].freeze

    def initialize(argv)
      @argv = argv.dup
      @options = DEFAULTS.dup
    end

    def run
      command = parse!
      return usage unless COMMANDS.include?(command)

      public_send(:"cmd_#{command}")
    rescue Routing::Error => e
      warn "Ошибка: #{e.message}"
      2
    rescue Errno::ENOENT => e
      warn "Не найден файл: #{e.message}"
      2
    end

    # --- команды ------------------------------------------------------------

    def cmd_plan
      router = build_router
      say "Профиль:            #{router.config.fetch('profile')}"
      say "Режим согласования: #{router.config.fetch('scoring', 'mode')} " \
          "(эпсилон #{router.config.fetch('scoring', 'tier_epsilon')})"
      say "Тай-брейк:          #{Array(router.config.fetch('scoring', 'tie_break')).join(' -> ')}"
      say ""
      say "Жёсткие ограничения (#{router.constraints.size}), в порядке проверки:"
      router.constraints.each_with_index { |c, i| say "  #{i + 1}. #{c.id}" }
      say ""
      say "Цели маршрутизации (#{router.strategies.size}):"
      router.strategies.group_by(&:tier).sort.each do |tier, group|
        say "  эшелон #{tier}:"
        group.sort_by(&:id).each { |s| say format("    %-22s вес %.2f", s.id, s.weight) }
      end
      say ""
      say "Провайдеры: #{router.fleet.ids.join(', ')}"
      say "История:    #{router.calibration.size} операций"
      report_issues(router.issues)
      0
    end

    def cmd_decisions
      router = build_router
      operations = load_operations(router)
      decisions = router.route_all(operations)
      write_decisions(decisions)
      summarize(decisions, router)
      report_issues(router.issues)
      finish(router)
    end

    def cmd_report
      router = build_router
      operations = load_operations(router)
      decisions = router.route_all(operations)
      write_report(router, decisions)
      report_issues(router.issues)
      finish(router)
    end

    def cmd_run
      router = build_router
      operations = load_operations(router)
      decisions = router.route_all(operations)
      write_decisions(decisions)
      write_report(router, decisions)
      summarize(decisions, router)
      report_issues(router.issues)
      finish(router)
    end

    # Один и тот же вход, разные профили — наглядно показывает, что поведение
    # задаётся настройками, а не зашито в код.
    def cmd_compare
      base = Config.load(@options[:config])
      profiles = ["balanced"] + base.profiles
      rows = profiles.map do |name|
        config = name == "balanced" ? base : base.with_profile(name)
        router = build_router(config)
        decisions = router.route_all(load_operations(router))
        distribution = decisions.group_by(&:selected_provider).transform_values(&:size)
        approved = decisions.count(&:approved?)
        [name, distribution, approved, decisions.sum(&:latency_sec)]
      end

      providers = rows.flat_map { |row| row[1].keys }.compact.uniq.sort
      header = format("%-18s %5s %7s  %s", "профиль", "одобр", "задержка",
                      providers.map { |p| p[0, 8].rjust(8) }.join(" "))
      say header
      say "-" * header.length
      rows.each do |name, distribution, approved, latency|
        say format("%-18s %5d %7d  %s", name, approved, latency,
                   providers.map { |p| distribution.fetch(p, 0).to_s.rjust(8) }.join(" "))
      end
      0
    end

    def cmd_validate
      script = "scripts/validate_10.rb"
      unless File.exist?(script)
        warn "Скрипт проверки #{script} не найден"
        return 2
      end

      system(RbConfig.ruby, script, @options[:decisions]) ? 0 : 1
    end

    private

    # --- сборка -------------------------------------------------------------

    def build_router(config = nil)
      config ||= begin
        loaded = Config.load(@options[:config])
        @options[:profile] ? loaded.with_profile(@options[:profile]) : loaded
      end
      config = apply_overlays(config)

      Router.build(config: config,
                   providers_path: @options[:providers],
                   history_path: @options[:history])
    end

    # Накладка с полями, выведенными из истории. Отдельный файл, а не правка
    # providers.json: входные данные организаторов остаются нетронутыми,
    # а наши допущения видно отдельно и их легко отключить.
    def apply_overlays(config)
      path = @options[:overlays]
      return config if path.nil? || !File.exist?(path)

      overlay = YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: true) || {}
      providers = overlay["providers"]
      return config unless providers.is_a?(Hash)

      config.merge("ingest" => { "provider_overlays" => providers })
    end

    def load_operations(router)
      loader = Ingest::Loader.new(router.config, issues: router.issues)
      loader.load_operations(@options[:queue])
    end

    # --- вывод --------------------------------------------------------------

    def write_decisions(decisions)
      write_json(@options[:decisions], decisions.map(&:to_h))
      strict_path = @options[:decisions].sub(/\.json\z/, ".strict.json")
      write_json(strict_path, decisions.map(&:to_strict_h))
      say "Решения:  #{@options[:decisions]} (#{decisions.size}) и #{strict_path}"
    end

    def write_report(router, decisions)
      report = Analytics::Report.new(
        decisions: decisions, fleet: router.fleet, config: router.config,
        period: router.period, calibration: router.calibration,
        issues: router.issues, meta: router.meta, describe: router.describe
      )
      write_json(@options[:report], report.to_h)
      say "Отчёт:    #{@options[:report]}"
      report
    end

    # Запись через временный файл: прерванный прогон не оставит после себя
    # наполовину записанный JSON, который автопроверка не сможет прочитать.
    def write_json(path, payload)
      directory = File.dirname(path)
      FileUtils.mkdir_p(directory) unless File.directory?(directory)
      temporary = "#{path}.tmp"
      File.write(temporary, "#{JSON.pretty_generate(payload)}\n")
      File.rename(temporary, path)
    end

    def summarize(decisions, router)
      total = decisions.size
      say ""
      say "Заявок: #{total}, одобрено: #{decisions.count(&:approved?)}"
      counts = decisions.group_by(&:selected_provider).transform_values(&:size)
      router.fleet.providers.each do |provider|
        count = counts.fetch(provider.id, 0)
        target = router.fleet.count_target(provider.id) * 100
        share = total.zero? ? 0 : count * 100.0 / total
        say format("  %-14s %2d  %5.1f%%  цель %5.1f%%  %+6.1f п.п.",
                   provider.id, count, share, target, share - target)
      end
    end

    def report_issues(issues)
      return if issues.nil? || issues.empty?

      counts = issues.count_by_severity
      say ""
      say "Замечания к данным: #{counts.map { |k, v| "#{k} #{v}" }.join(', ')}"
      issues.each { |issue| say "  #{issue}" } unless @options[:quiet]
    end

    def finish(router)
      return 1 if @options[:strict] && router.issues.any_errors?

      0
    end

    # Не сокращать до однострочного def: модификатор unless в endless-методе
    # относится к самому определению, а не к телу, и метод просто не создастся.
    def say(text)
      puts(text) unless @options[:quiet]
    end

    # --- аргументы ----------------------------------------------------------

    def parse!
      parser = OptionParser.new do |opts|
        opts.banner = "Использование: bin/route <#{COMMANDS.join('|')}> [опции]"
        opts.on("--config PATH", "конфигурация маршрутизации") { |v| @options[:config] = v }
        opts.on("--overlays PATH", "накладка с выведенными полями провайдеров") { |v| @options[:overlays] = v }
        opts.on("--providers PATH", "состояние провайдеров") { |v| @options[:providers] = v }
        opts.on("--queue PATH", "очередь заявок") { |v| @options[:queue] = v }
        opts.on("--history PATH", "история операций") { |v| @options[:history] = v }
        opts.on("--decisions PATH", "куда писать решения") { |v| @options[:decisions] = v }
        opts.on("--report PATH", "куда писать отчёт") { |v| @options[:report] = v }
        opts.on("--profile NAME", "профиль стратегии") { |v| @options[:profile] = v }
        opts.on("--strict", "ненулевой код возврата при ошибках в данных") { @options[:strict] = true }
        opts.on("--quiet", "меньше вывода") { @options[:quiet] = true }
        opts.on("-h", "--help", "справка") { puts opts; exit 0 }
      end
      parser.parse!(@argv)
      @argv.shift
    end

    def usage
      warn "Использование: bin/route <#{COMMANDS.join('|')}> [опции]"
      warn "Подробности: bin/route --help"
      1
    end
  end
end
