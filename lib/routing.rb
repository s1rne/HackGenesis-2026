# frozen_string_literal: true

require "json"
require "csv"
require "yaml"
require "time"
require "date"
require "digest"
require "fileutils"
require "rbconfig"

# Умный роутинг выплат.
#
# Разделение по назначению:
#   ingest/      — чтение и приведение входных данных, терпимое к формату;
#   constraints/ — жёсткие ограничения: можно ли отправить заявку провайдеру;
#   strategies/  — мягкие цели: кого предпочесть среди допустимых;
#   scorer       — согласование конфликтующих целей;
#   cascade      — порядок попыток, отказы и fallback;
#   analytics/   — отчёт, метрики и рекомендации.
module Routing
  ROOT = File.expand_path("..", __dir__)
end

require_relative "routing/version"
require_relative "routing/errors"
require_relative "routing/money"
require_relative "routing/statistics"
require_relative "routing/bank"
require_relative "routing/config"
require_relative "routing/reasons"

require_relative "routing/ingest/issues"
require_relative "routing/ingest/field_map"
require_relative "routing/ingest/record"

require_relative "routing/operation"
require_relative "routing/provider"
require_relative "routing/provider_state"
require_relative "routing/fleet"
require_relative "routing/evaluation_context"

require_relative "routing/constraints/base"
Dir[File.join(__dir__, "routing/constraints/*.rb")].sort.each { |file| require file }

require_relative "routing/strategies/base"
Dir[File.join(__dir__, "routing/strategies/*.rb")].sort.each { |file| require file }

require_relative "routing/scorer"
require_relative "routing/clock"
require_relative "routing/decision"
require_relative "routing/calibration"
require_relative "routing/simulator"
require_relative "routing/cascade"
require_relative "routing/analytics/recommendations"
require_relative "routing/analytics/report"
require_relative "routing/analytics/achievability"
require_relative "routing/analytics/replay"
require_relative "routing/ingest/loader"
require_relative "routing/router"
require_relative "routing/cli"
