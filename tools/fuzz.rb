# frozen_string_literal: true

# Обстрел роутера случайными очередями.
#
# Боевую очередь выдают за час до стопкода, и увидеть её заранее нельзя.
# Единственная доступная страховка — прогнать конвейер на очередях, которых
# никто не писал руками, и проверить, что выгрузка остаётся сдаваемой.
#
#   ruby tools/fuzz.rb                 # 200 очередей
#   ruby tools/fuzz.rb --cases 2000    # длинный прогон
#   ruby tools/fuzz.rb --seed 12345    # повторить конкретный случай
#
# Каждая очередь проверяется на семь утверждений, любое нарушение печатается
# вместе с зерном, по которому очередь воспроизводится дословно, и сама очередь
# сохраняется в out/fuzz/.

require "json"
require "fileutils"
require "optparse"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "routing"

module Fuzz
  ROOT = File.expand_path("..", __dir__)
  CONFIG = File.join(ROOT, "config", "routing.yml")
  PROVIDERS = File.join(ROOT, "data", "providers.json")
  HISTORY = File.join(ROOT, "data", "operations_history.csv")
  FAILURES_DIR = File.join(ROOT, "out", "fuzz")

  # Банки: половина известна провайдерам, половина — нет. Неизвестный банк не
  # должен ронять прогон, он должен отсеивать провайдеров по правилу.
  KNOWN_BANKS = %w[sberbank tinkoff vtb alfa].freeze
  UNKNOWN_BANKS = ["raiffeisen", "ozon", "psb", "sovcombank", "", nil,
                   "SBERBANK", " sberbank ", "сбербанк", "unknown_bank_42"].freeze

  # Суммы подобраны вокруг границ провайдеров: 500, 1000, 50000, 100000.
  # Внутри диапазона случайность мало что ловит, ошибки живут на краях.
  EDGE_AMOUNTS = [0, 1, 499, 500, 501, 999, 1000, 1001, 49_999, 50_000, 50_001,
                  99_999, 100_000, 100_001, 1_000_000, 10_000_000].freeze

  Case = Struct.new(:seed, :kind, :queue, keyword_init: true)

  Failure = Struct.new(:seed, :kind, :size, :reason, keyword_init: true) do
    def to_s = "seed=#{seed} вид=#{kind} заявок=#{size}: #{reason}"
  end

  module_function

  # --- генерация ----------------------------------------------------------

  def build_case(seed)
    rng = Random.new(seed)
    kind = %i[plausible edgy hostile].sample(random: rng)
    size = case kind
           when :plausible then rng.rand(1..120)
           when :edgy then rng.rand(1..40)
           else rng.rand(1..25)
           end

    start = Time.at(rng.rand(1_700_000_000..1_800_000_000)).utc
    step = [0, 1, 30, 600, 86_400].sample(random: rng)

    rows = Array.new(size) do |index|
      row(rng, kind, index, start + (index * step))
    end
    rows.shuffle!(random: rng) if rng.rand < 0.2

    Case.new(seed: seed, kind: kind, queue: rows)
  end

  def row(rng, kind, index, at)
    base = {
      "operation_id" => format("fz_%04d", index + 1),
      "created_at" => at.strftime("%Y-%m-%dT%H:%M:%S+03:00"),
      "amount" => amount(rng, kind),
      "bank" => bank(rng, kind),
      "card_brand" => rng.rand < 0.15 ? %w[visa mastercard mir].sample(random: rng) : nil,
      "payout_requisite" => requisite(rng, kind)
    }
    return base unless kind == :hostile

    # Враждебный вид ломает форму записи: убирает поля, подставляет чужие типы
    # и добавляет мусор. Ожидание здесь — не корректная выгрузка, а понятная
    # ошибка вместо трассировки стека.
    base.delete(%w[created_at amount bank payout_requisite].sample(random: rng)) if rng.rand < 0.5
    base["amount"] = ["12000", nil, -500, 12_000.75, {}, []].sample(random: rng) if rng.rand < 0.5
    base["created_at"] = ["вчера", "", nil, 0, "2026-13-45T99:99:99"].sample(random: rng) if rng.rand < 0.4
    base["мусор"] = "поле, которого нет в контракте" if rng.rand < 0.3
    base
  end

  def amount(rng, kind)
    return EDGE_AMOUNTS.sample(random: rng) if kind == :edgy || rng.rand < 0.3

    rng.rand(500..120_000)
  end

  def bank(rng, kind)
    return UNKNOWN_BANKS.sample(random: rng) if kind != :plausible && rng.rand < 0.5

    KNOWN_BANKS.sample(random: rng)
  end

  def requisite(rng, kind)
    return nil if kind != :plausible && rng.rand < 0.25

    if rng.rand < 0.8
      { "sbp" => { "phone" => "7900#{rng.rand(1_000_000..9_999_999)}", "bank_name" => "Банк" } }
    else
      { "card" => { "pan" => "220#{rng.rand(1_000_000_000_000..9_999_999_999_999)}" } }
    end
  end

  # --- проверка -----------------------------------------------------------

  # Один прогон: очередь на диск, конвейер, семь утверждений. Возвращает список
  # нарушений — пустой, если очередь прошла.
  def check(kase, dir)
    path = File.join(dir, "queue.json")
    File.write(path, JSON.pretty_generate(kase.queue))

    first = run_once(path)
    return [first[:error]] if first[:error]

    problems = invariants(first)

    # Детерминизм: тот же вход обязан дать байт в байт тот же результат.
    # Проверяется не на каждой очереди — это удвоение времени прогона.
    if kase.seed.even?
      second = run_once(path)
      problems << "повторный прогон дал другой результат" if second[:dump] != first[:dump]
    end

    problems
  end

  def run_once(queue_path)
    config = Routing::Config.load(CONFIG)
    router = Routing::Router.build(config: config, providers_path: PROVIDERS, history_path: HISTORY)
    loader = Routing::Ingest::Loader.new(router.config, issues: router.issues)
    operations = loader.load_operations(queue_path)
    decisions = router.route_all(operations)

    report = Routing::Analytics::Report.new(
      decisions: decisions, fleet: router.fleet, config: router.config,
      period: router.period(decisions.map(&:operation)), calibration: router.calibration,
      issues: router.issues, meta: router.meta,
      describe: router.describe(decisions.map(&:operation)),
      constraints: router.constraints
    )

    { operations: operations, decisions: decisions, router: router,
      report: report.to_h, dump: JSON.generate(decisions.map(&:to_strict_h)) }
  rescue Routing::Error => e
    # Осознанная ошибка домена — допустимый исход на враждебном входе.
    { handled: e.message }
  rescue StandardError => e
    { error: "#{e.class}: #{e.message} (#{e.backtrace&.first})" }
  end

  def invariants(result)
    return [] if result[:handled]

    problems = []
    operations = result[:operations]
    decisions = result[:decisions]

    problems << "решений #{decisions.size}, заявок #{operations.size}" if decisions.size != operations.size

    ids = decisions.map { |d| d.operation.id }
    problems << "дубли operation_id в выгрузке" if ids.uniq.size != ids.size

    without = decisions.reject(&:selected_provider)
    problems << "без selected_provider: #{without.size}" unless without.empty?

    problems.concat(Routing::Delivery.integrity_problems(decisions))

    JSON.parse(result[:dump])

    missing = Routing::Delivery::REQUIRED_REPORT_KEYS.reject { |key| result[:report].key?(key) }
    problems << "в отчёте нет разделов: #{missing.join(', ')}" unless missing.empty?

    Routing::GraderCheck.checks(
      operations: operations, decisions: decisions, providers_path: PROVIDERS
    ).each { |ok, note| problems << "модель проверяющего: #{note}" unless ok }

    problems
  rescue StandardError => e
    ["проверка инвариантов упала: #{e.class}: #{e.message}"]
  end

  # --- прогон -------------------------------------------------------------

  def run(cases:, seed:, quiet:)
    failures = []
    kinds = Hash.new(0)
    handled = 0

    dir = File.join(Dir.tmpdir, "routing-fuzz-#{Process.pid}")
    FileUtils.mkdir_p(dir)

    cases.times do |index|
      kase = build_case(seed + index)
      kinds[kase.kind] += 1
      problems = check(kase, dir)

      problems.each do |reason|
        failures << Failure.new(seed: kase.seed, kind: kase.kind, size: kase.queue.size, reason: reason)
        save_failure(kase)
      end

      print_progress(index + 1, cases, failures.size) unless quiet
    end

    puts unless quiet
    report(cases, kinds, failures, handled)
    failures.empty? ? 0 : 1
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def save_failure(kase)
    FileUtils.mkdir_p(FAILURES_DIR)
    File.write(File.join(FAILURES_DIR, "seed_#{kase.seed}.json"), JSON.pretty_generate(kase.queue))
  end

  def print_progress(done, total, failed)
    return unless (done % 25).zero? || done == total

    $stdout.print("\r  #{done}/#{total} очередей, нарушений: #{failed}   ")
    $stdout.flush
  end

  def report(cases, kinds, failures, _handled)
    puts "Обстрел: #{cases} очередей"
    puts "  по видам: " + kinds.map { |kind, count| "#{kind} #{count}" }.join(", ")

    if failures.empty?
      puts "  нарушений инвариантов: нет"
      puts
      puts "Ни одна из #{cases} сгенерированных очередей не сломала выгрузку."
      return
    end

    puts "  нарушений инвариантов: #{failures.size}"
    puts
    failures.first(20).each { |failure| puts "  #{failure}" }
    puts "  … и ещё #{failures.size - 20}" if failures.size > 20
    puts
    puts "Очереди-нарушители сохранены в #{FAILURES_DIR}, повтор: ruby tools/fuzz.rb --seed <seed> --cases 1"
  end
end

if $PROGRAM_NAME == __FILE__
  require "tmpdir"

  options = { cases: 200, seed: 1, quiet: false }
  OptionParser.new do |parser|
    parser.banner = "Использование: ruby tools/fuzz.rb [--cases N] [--seed S] [--quiet]"
    parser.on("--cases N", Integer, "сколько очередей сгенерировать (по умолчанию 200)") { |v| options[:cases] = v }
    parser.on("--seed S", Integer, "начальное зерно (по умолчанию 1)") { |v| options[:seed] = v }
    parser.on("--quiet", "без строки прогресса") { options[:quiet] = true }
  end.parse!(ARGV)

  exit Fuzz.run(**options)
end
