# frozen_string_literal: true

# Задачи проекта. Только стандартная библиотека: ни гемов, ни Bundler.
#
#   rake test        — весь набор тестов
#   rake run         — прогон конвейера в корень репозитория
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
