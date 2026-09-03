# frozen_string_literal: true

module Routing
  module Ingest
    # Чтение CSV без единой зависимости.
    #
    # Казалось бы, зачем: в Ruby есть библиотека CSV. Но начиная с Ruby 3.4
    # она перестала быть частью ядра и превратилась в bundled gem — то есть
    # ставится вместе с интерпретатором, но формально это уже гем. На обычной
    # машине разницы нет, а на урезанном окружении или под Bundler без
    # объявленной зависимости `require "csv"` падает.
    #
    # Мы обещаем, что решение запускается одной командой на голом Ruby.
    # Обещание должно быть точным, поэтому двадцать строк разбора здесь
    # лучше, чем оговорка в README.
    #
    # Поддерживается то, что и требуется от CSV: кавычки, запятые и переводы
    # строк внутри кавычек, удвоенная кавычка как экранирование, CRLF, BOM.
    module CsvReader
      module_function

      # Возвращает массив хэшей «заголовок => значение», как CSV.read(headers: true).
      def read(path)
        rows = parse(File.read(path, encoding: "bom|utf-8"))
        return [] if rows.empty?

        headers = rows.shift
        rows.reject { |row| row.all? { |cell| cell.nil? || cell.empty? } }
            .map { |row| headers.each_with_index.to_h { |name, index| [name, row[index]] } }
      end

      def parse(text)
        rows = []
        row = []
        field = +""
        quoted = false      # находимся ли внутри кавычек прямо сейчас
        was_quoted = false  # были ли кавычки у этого поля вообще
        index = 0
        length = text.length

        # Пустое поле без кавычек — это отсутствие значения (nil), пустое
        # в кавычках — пустая строка. Разница не косметическая: так же ведёт себя
        # стандартная библиотека, и разбор обязан совпадать с ней до символа.
        finish = lambda do
          row << (field.empty? && !was_quoted ? nil : field)
          field = +""
          was_quoted = false
        end

        while index < length
          char = text[index]

          if quoted
            if char == '"'
              if text[index + 1] == '"'
                field << '"'
                index += 1
              else
                quoted = false
              end
            else
              field << char
            end
          elsif char == '"' && field.empty?
            quoted = true
            was_quoted = true
          elsif char == ","
            finish.call
          elsif char == "\n" || char == "\r"
            index += 1 if char == "\r" && text[index + 1] == "\n"
            finish.call
            rows << row
            row = []
          else
            field << char
          end

          index += 1
        end

        unless field.empty? && !was_quoted && row.empty?
          finish.call
          rows << row
        end

        rows
      end
    end
  end
end
