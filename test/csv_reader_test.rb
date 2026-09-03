# frozen_string_literal: true

require_relative "test_helper"

# Разбор CSV своими силами.
#
# Ожидаемые значения записаны здесь явно, а не сверяются с библиотекой CSV:
# смысл этого модуля в том, чтобы библиотеки не было, и тест, который её
# требует, проверял бы не то, что нужно. Значения выверены по её поведению
# один раз при написании.
class CsvReaderTest < Minitest::Test
  include RoutingTest

  R = Routing::Ingest::CsvReader

  def test_reads_the_case_history_file
    rows = R.read(RoutingTest::HISTORY_PATH)

    assert_equal 100, rows.size
    assert_equal %w[operation_id created_at amount bank card_brand payment_system status latency_sec],
                 rows.first.keys
    assert_equal "op_001", rows.first["operation_id"]
    assert_equal "vipay", rows.first["payment_system"]
    assert_equal "approved", rows.first["status"]
  end

  # Пустое поле без кавычек — это отсутствие значения, а не пустая строка.
  # Столбец card_brand в истории пуст во всех ста строках, и если бы он
  # читался как "", проверки «поле не заполнено» перестали бы срабатывать.
  def test_empty_unquoted_field_is_nil_and_quoted_empty_is_a_string
    assert_equal [%w[a b c], ["1", nil, "3"], [nil, "", nil]],
                 R.parse(%(a,b,c\n1,,3\n,"",\n))
  end

  def test_quotes_commas_and_newlines_inside_a_field
    assert_equal [%w[a b c], ["1", "два, с запятой", "три\nс переносом"]],
                 R.parse(%(a,b,c\n1,"два, с запятой","три\nс переносом"\n))
  end

  def test_doubled_quote_is_an_escaped_quote
    assert_equal [%w[a b], ["1", 'он сказал "да"']],
                 R.parse(%(a,b\n1,"он сказал ""да"""\n))
  end

  def test_crlf_line_endings
    assert_equal [%w[a b], %w[1 2]], R.parse("a,b\r\n1,2\r\n")
  end

  def test_file_without_a_trailing_newline
    assert_equal [%w[a b], %w[1 2]], R.parse("a,b\n1,2")
  end

  def test_single_column
    assert_equal [["a"], ["1"], ["2"]], R.parse("a\n1\n2\n")
  end

  def test_byte_order_mark_is_stripped
    dir = Dir.mktmpdir("csv-bom-")
    path = File.join(dir, "bom.csv")
    File.write(path, "﻿id,value\n1,два\n")

    rows = R.read(path)
    assert_equal %w[id value], rows.first.keys, "BOM не должен приклеиваться к первому заголовку"
    assert_equal "два", rows.first["value"]
  ensure
    FileUtils.remove_entry(dir, true) if dir
  end

  def test_blank_lines_are_skipped_in_read
    dir = Dir.mktmpdir("csv-blank-")
    path = File.join(dir, "blank.csv")
    File.write(path, "id,value\n1,a\n\n2,b\n")

    assert_equal 2, R.read(path).size
  ensure
    FileUtils.remove_entry(dir, true) if dir
  end

  # Главное обещание проекта: запускается одной командой на голом Ruby.
  # Флаг --disable-gems выключает вообще всё, включая поставляемые
  # с интерпретатором гемы, — если конвейер работает и так, обещание точное.
  def test_the_whole_pipeline_runs_with_gems_disabled
    dir = Dir.mktmpdir("no-gems-")
    decisions = File.join(dir, "decisions.json")
    report = File.join(dir, "report.json")

    output = nil
    status = nil
    Dir.chdir(RoutingTest::PROJECT_ROOT) do
      read, write = IO.pipe
      pid = Process.spawn(RoutingTest::RUBY, "--disable-gems", "bin/route", "run", "--quiet",
                          "--decisions", decisions, "--report", report, out: write, err: write)
      write.close
      output = read.read
      _, status = Process.wait2(pid)
      read.close
    end

    assert_equal 0, status.exitstatus, "прогон без гемов завершился с ошибкой:\n#{output}"
    assert_equal 10, JSON.parse(File.read(decisions)).size
  ensure
    FileUtils.remove_entry(dir, true) if dir
  end
end
