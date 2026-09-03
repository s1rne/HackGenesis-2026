# frozen_string_literal: true

module Routing
  module Ingest
    # Чтение входных данных.
    #
    # Загрузчик намеренно терпим к форме файла: провайдеры приходят и как
    # массив, и как объект с ключом `providers` рядом со служебными полями
    # вроде `snapshot_at`. Угадывать структуру по имени файла — путь к падению
    # на первом же новом наборе данных, поэтому мы разбираем то, что видим.
    class Loader
      PROVIDER_COLLECTION_KEYS = %w[providers items list data payment_systems].freeze
      OPERATION_COLLECTION_KEYS = %w[operations queue items list data].freeze

      attr_reader :config, :issues, :meta

      def initialize(config, issues: Issues.new)
        @config = config
        @issues = issues
        @field_map = FieldMap.new(config.section("ingest", "field_aliases"))
        @bank_aliases = normalize_bank_aliases(config.section("ingest", "bank_aliases"))
        @defaults = config.section("ingest", "defaults").transform_keys(&:to_sym)
        @meta = {}
      end

      def load_fleet(path)
        payload = read_json(path)
        rows, envelope = unwrap(payload, PROVIDER_COLLECTION_KEYS, path)
        @meta.merge!(envelope)

        fallback_id = config.fetch("run", "fallback_provider")
        overlays = config.section("ingest", "provider_overlays")
        providers = rows.each_with_index.map do |row, index|
          source = "#{File.basename(path)}[#{index}]"
          record = Record.new(apply_overlay(row, overlays, source),
                              field_map: @field_map, issues: issues, source: source)
          Provider.from_record(record, defaults: @defaults, bank_aliases: @bank_aliases,
                                       self_provider_ids: Array(fallback_id))
        end

        halt_on_empty(providers, path, "провайдеров")
        warn_on_duplicates(providers.map(&:id), path, "провайдер")
        report_unknown_fields(providers, path)
        Fleet.new(providers, issues: issues)
      end

      def load_operations(path)
        payload = read_json(path)
        rows, envelope = unwrap(payload, OPERATION_COLLECTION_KEYS, path)
        @meta.merge!(envelope) unless envelope.empty?

        operations = rows.each_with_index.map do |row, index|
          record = Record.new(row, field_map: @field_map, issues: issues, source: "#{File.basename(path)}[#{index}]")
          Operation.from_record(record, index: index, bank_aliases: @bank_aliases)
        end

        halt_on_empty(operations, path, "заявок")
        warn_on_duplicates(operations.map(&:id), path, "заявка")
        operations
      end

      # История нужна для калибровки: наблюдаемая конверсия, средняя задержка,
      # фактические доли. Её отсутствие не должно ломать прогон — роутер
      # обязан работать и на пустой истории, просто без калибровки.
      def load_history(path)
        return [] if path.nil? || !File.exist?(path)

        rows = CsvReader.read(path)
        rows.each_with_index.map do |row, index|
          record = Record.new(row, field_map: @field_map, issues: issues, source: "#{File.basename(path)}[#{index}]")
          {
            operation_id: record.string("operation_id"),
            created_at: record.time("created_at"),
            amount: record.money("amount", default: 0),
            bank: Bank.normalize(record.string("bank"), @bank_aliases),
            provider: record.string("id"),
            status: (record.string("status") || "unknown").downcase,
            latency_sec: record.float("avg_latency_sec") || record.float("latency_sec")
          }
        end
      rescue StandardError => e
        issues.error(File.basename(path), "файл истории не разбирается как CSV: #{e.message}")
        []
      end

      private

      # Накладка с полями, выведенными из истории: volume_share_pct,
      # requests_per_minute_limit, обязательства по обороту. Она НЕ перекрывает
      # то, что уже пришло от организаторов, — только дополняет пустые места.
      # Так исходные данные остаются исходными, а наши допущения видно отдельно.
      def apply_overlay(row, overlays, source)
        return row if overlays.nil? || overlays.empty?

        id = row.values_at("payment_system", "id", "name").compact.first
        extra = overlays[id.to_s]
        return row unless extra.is_a?(Hash)

        added = extra.reject { |key, _| row.key?(key) && !row[key].nil? }
        return row if added.empty?

        issues.info(source, "поля из накладки: #{added.keys.sort.join(', ')}")
        row.merge(added)
      end

      def read_json(path)
        raise DataError.new("файл не найден", source: path) unless File.exist?(path)

        content = File.read(path)
        raise DataError.new("файл пуст", source: path) if content.strip.empty?

        JSON.parse(content)
      rescue JSON::ParserError => e
        raise DataError.new("не разбирается как JSON: #{e.message}", source: path)
      end

      # Достаёт коллекцию из объекта-обёртки и возвращает вместе с остальными
      # полями верхнего уровня — snapshot_at, gateway, merchant попадают в отчёт.
      def unwrap(payload, keys, path)
        return [payload, {}] if payload.is_a?(Array)

        unless payload.is_a?(Hash)
          raise DataError.new("ожидался массив или объект, получено #{payload.class}", source: path)
        end

        key = keys.find { |candidate| payload[candidate].is_a?(Array) }
        unless key
          found = payload.keys.join(", ")
          raise DataError.new("не найден массив записей; известные ключи: #{keys.join(', ')}, в файле: #{found}",
                              source: path)
        end

        [payload[key], payload.reject { |k, _| k == key }]
      end

      def halt_on_empty(collection, path, what)
        raise DataError.new("не найдено ни одной записи #{what}", source: path) if collection.empty?
      end

      def warn_on_duplicates(ids, path, what)
        duplicates = ids.tally.select { |_, count| count > 1 }.keys
        return if duplicates.empty?

        issues.warning(File.basename(path), "#{what} встречается более одного раза: #{duplicates.join(', ')}")
      end

      def report_unknown_fields(providers, path)
        unknown = providers.flat_map(&:unknown_fields).tally
        return if unknown.empty?

        issues.info(File.basename(path),
                    "поля без известного смысла сохранены как есть: #{unknown.keys.sort.join(', ')}")
      end

      def normalize_bank_aliases(aliases)
        (aliases || {}).to_h { |key, value| [Bank.normalize(key), Bank.normalize(value)] }
      end
    end
  end
end
