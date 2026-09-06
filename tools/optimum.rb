# frozen_string_literal: true

# Насколько наш результат далёк от лучшего возможного.
#
# Отклонение от целевых долей само по себе ничего не говорит: 35 процентных
# пунктов — это плохо или это всё, что позволяет очередь? Раздел достижимости
# в отчёте отвечает на половину вопроса — он считает нижнюю границу по
# коридорам. Но граница не обязана достигаться.
#
# Здесь считается вторая половина: берём нашу раскладку и перебираем все
# одиночные переносы заявок и все парные обмены, соблюдая допуск и дневные
# лимиты по деньгам. Если улучшающих ходов не осталось — мы в локальном
# оптимуме. Если остались, видно, сколько именно потеряно и на чём.
#
# Важная оговорка: этот перебор знает всю очередь заранее, а роутер решает
# по каждой заявке, не видя следующих. Разрыв между онлайном и оптимумом
# с полным знанием будущего неизбежен — вопрос лишь в его величине.
#
#   ruby tools/optimum.rb
#   ruby tools/optimum.rb --decisions routing_decisions.json --queue data/operations_queue_10.json

require "json"
require "optparse"

module Optimum
  ROOT = File.expand_path("..", __dir__)
  SELF_PROVIDER = "spacepayments"

  module_function

  # Допустимость по снимку — те же условия и в том же порядке, что в скрипте
  # автопроверки. Правила состояния он не проверяет, и мы здесь тоже: задача
  # перебора — оценить пространство выбора, а не повторить прогон.
  def eligible(operation, providers)
    amount = operation["amount"].to_f
    bank = operation["bank"]

    providers.filter_map do |provider|
      next unless provider["status"] == "active"
      next if provider["traffic_percentage"].to_f.zero? && provider["payment_system"] != SELF_PROVIDER
      next if provider["limit_amount_min"] && amount < provider["limit_amount_min"]
      next if provider["limit_amount_max"] && amount > provider["limit_amount_max"]
      next if provider["available_requisites"].to_i.zero?
      next if provider["provider_margin_pct"].to_f > provider["merchant_margin_pct"].to_f &&
              !provider["allow_negative_agreement"]
      next unless bank_allowed?(provider, bank)

      provider["payment_system"]
    end
  end

  def bank_allowed?(provider, bank)
    banks = provider["banks"] || []
    return true if banks.empty?

    provider["exclude_banks"] ? !banks.include?(bank) : banks.include?(bank)
  end

  # Отклонение фактических долей от целевых, в процентных пунктах.
  # Половина суммы модулей — это расстояние полной вариации.
  def deviation(assignment, targets, total)
    counts = Hash.new(0)
    assignment.each_value { |id| counts[id] += 1 }
    targets.sum { |id, target| ((counts[id] / total * 100) - target).abs } / 2.0
  end

  def within_limits?(assignment, amounts, headroom)
    spent = Hash.new(0.0)
    assignment.each { |operation_id, provider_id| spent[provider_id] += amounts[operation_id] }
    spent.all? { |provider_id, sum| sum <= headroom[provider_id] + 1e-6 }
  end

  def run(decisions_path:, queue_path:, providers_path:)
    providers = JSON.parse(File.read(providers_path))["providers"]
    queue = JSON.parse(File.read(queue_path))
    ours = JSON.parse(File.read(decisions_path))
               .to_h { |item| [item["operation_id"], item["selected_provider"]] }

    amounts = queue.to_h { |op| [op["operation_id"], op["amount"].to_f] }
    options = queue.to_h { |op| [op["operation_id"], eligible(op, providers)] }
    targets = providers.to_h { |p| [p["payment_system"], p["traffic_percentage"].to_f] }
    headroom = providers.to_h do |p|
      limit = p["daily_amount_limit"]
      [p["payment_system"], limit ? limit - p["daily_approved_amount"].to_f : Float::INFINITY]
    end
    total = queue.size.to_f

    ours_value = deviation(ours, targets, total)
    best = improve(ours, queue, options, amounts, headroom, targets, total)
    best_value = deviation(best, targets, total)

    report(ours, best, ours_value, best_value, options, queue)
    0
  end

  # Локальный поиск: одиночные переносы, затем парные обмены, пока
  # находятся улучшения.
  def improve(start, queue, options, amounts, headroom, targets, total)
    current = start.dup
    best = deviation(current, targets, total)

    loop do
      improved = false

      queue.each do |operation|
        id = operation["operation_id"]
        options[id].each do |provider_id|
          next if provider_id == current[id]

          trial = current.merge(id => provider_id)
          next unless within_limits?(trial, amounts, headroom)

          value = deviation(trial, targets, total)
          next unless value < best - 1e-9

          current = trial
          best = value
          improved = true
        end
      end

      queue.combination(2) do |left, right|
        a = left["operation_id"]
        b = right["operation_id"]
        next if current[a] == current[b]
        next unless options[a].include?(current[b]) && options[b].include?(current[a])

        trial = current.merge(a => current[b], b => current[a])
        next unless within_limits?(trial, amounts, headroom)

        value = deviation(trial, targets, total)
        next unless value < best - 1e-9

        current = trial
        best = value
        improved = true
      end

      break current unless improved
    end
  end

  def report(ours, best, ours_value, best_value, options, queue)
    choice = options.count { |_, list| (list - [SELF_PROVIDER]).size > 1 }
    puts "Заявок: #{queue.size}, из них с реальным выбором: #{choice}"
    puts
    puts "  наш результат:                    #{format('%.1f', ours_value)} п.п."
    puts "  оптимум со знанием всей очереди:  #{format('%.1f', best_value)} п.п."
    puts
    puts "  наша раскладка:      #{tally(ours)}"
    puts "  оптимальная:         #{tally(best)}"
    puts

    gap = ours_value - best_value
    if gap < 0.05
      puts "Улучшающих ходов не нашлось: раскладка оптимальна."
      return
    end

    moved = ours.count { |id, provider| best[id] != provider }
    puts "Разрыв #{format('%.1f', gap)} п.п. на #{moved} заявках. Важно, что перебор видит"
    puts "всю очередь сразу, а роутер решает по одной заявке, не зная следующих:"
    puts "часть разрыва — цена онлайн-решения, а не ошибка."
  end

  def tally(assignment)
    counts = Hash.new(0)
    assignment.each_value { |id| counts[id] += 1 }
    counts.sort_by { |_, count| -count }.map { |id, count| "#{id} #{count}" }.join(", ")
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    decisions: File.join(Optimum::ROOT, "routing_decisions_test.json"),
    queue: File.join(Optimum::ROOT, "data", "operations_queue_test.json"),
    providers: File.join(Optimum::ROOT, "data", "providers.json")
  }

  OptionParser.new do |parser|
    parser.banner = "Использование: ruby tools/optimum.rb [опции]"
    parser.on("--decisions PATH", "выгрузка решений") { |v| options[:decisions] = v }
    parser.on("--queue PATH", "очередь заявок") { |v| options[:queue] = v }
    parser.on("--providers PATH", "провайдеры") { |v| options[:providers] = v }
  end.parse!(ARGV)

  exit Optimum.run(decisions_path: options[:decisions], queue_path: options[:queue],
                   providers_path: options[:providers])
end
