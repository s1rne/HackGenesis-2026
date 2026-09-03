# frozen_string_literal: true

# Задачи проекта. Только стандартная библиотека: ни гемов, ни Bundler.
#
#   rake test        — весь набор тестов
#   rake run         — прогон конвейера в корень репозитория
#   rake alt         — прогон на втором, совершенно другом наборе данных
#   rake validate    — автопроверка организаторов по routing_decisions.json
#   rake check       — прогон + автопроверка + тесты

require "rake/testtask"
require "rbconfig"

RUBY = RbConfig.ruby

Rake::TestTask.new(:test) do |t|
  t.libs = %w[lib test]
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
  t.verbose = false
end

desc "Прогнать очередь заявок и собрать выгрузку"
task :run do
  sh RUBY, "bin/route", "run"
end

# Второй набор данных: другой шлюз, другие партнёры, другие имена полей,
# другая обёртка файла и своя конфигурация. Кода под него не написано ни
# строки — задача существует, чтобы это можно было проверить, а не поверить
# на слово. История и накладка отключены намеренно: обе относятся к
# кейсовому набору, а у этого шлюза своей истории нет.
ALT_DIR = "test/fixtures/alt_dataset"

desc "Прогон конвейера на альтернативном наборе данных"
task :alt do
  sh RUBY, "bin/route", "run",
     "--config", "#{ALT_DIR}/config.yml",
     "--providers", "#{ALT_DIR}/providers.json",
     "--queue", "#{ALT_DIR}/operations_queue.json",
     "--history", "",
     "--overlays", "",
     "--decisions", "out/alt_decisions.json",
     "--report", "out/alt_report.json"
end

desc "Автопроверка организаторов по routing_decisions.json"
task :validate do
  sh RUBY, "scripts/validate_10.rb", "routing_decisions.json"
end

desc "Показать собранный конвейер и настройки"
task :plan do
  sh RUBY, "bin/route", "plan"
end

desc "Полная проверка: прогон, автопроверка организаторов, тесты"
task check: %i[run validate test]

task default: :test
