#!/usr/bin/env ruby
# frozen_string_literal: true

# Согласованность схемы ГАР — прежде всего после дельт, которые меняют пути и ранги только у
# затронутых объектов:
#
#   GAR_DATABASE_URL=postgresql://… ruby examples/tools/check_consistency.rb [схема]
#
# 1. Инварианты: у действующих записей со строкой иерархии есть путь; OBJECTID пути
#    (*_path_ids) совпадают с PATH иерархии; у объекта не больше одной действующей актуальной
#    записи.
# 2. Пересчёт с нуля: таблицы копируются в схему <схема>_check без путей и рангов, PathBuilder
#    строит их заново, и они сравниваются с проверяемой схемой по id записи.
#
# Печатает число расхождений по каждой проверке и до 5 примеров; код выхода 1, если они есть.
# Схема по умолчанию — config.database_schema; <схема>_check удаляется после проверки.

require "bundler/setup"
require "gar"

schema = ARGV[0] || Gar.configuration.database_schema
check  = "#{schema}_check"
conn   = Gar::Database.create_connection
q      = ->(name, in_schema = schema) { Gar::Schema.qualify(in_schema, name) }
meta   = Gar::Meta.read(conn, schema) or abort("В схеме #{schema} нет gar_meta")
tables = meta.tables.map { Gar::Schema.fetch(_1) }.select { conn.exec_params("SELECT to_regclass($1)", [q.call(_1.name)]).getvalue(0, 0) }
paths  = tables.select(&:paths?).map(&:name)
hiers  = Gar::Configuration::HIERARCHY_TABLES.select { |_, table| tables.any? { _1.name == table } }
failed = false

report =
  lambda do |title, sql|
    rows = conn.exec(sql).values
    count = rows.size
    failed ||= count.positive?
    puts format("%-62<title>s %<count>d", title:, count:)
    rows.first(5).each { puts "    #{_1.map { |v| v.to_s[0, 120] }.join(' | ')}" }
  end

puts "Схема #{schema}: версия #{meta.version_id}, субъекты #{meta.region_codes.join(', ').then { _1.empty? ? 'все' : _1 }}"
puts "== Инварианты"
paths.each do |table|
  hiers.each do |hierarchy, hierarchy_table|
    report.call("#{table}: действующие без #{hierarchy}-пути при строке иерархии", <<~SQL)
      SELECT t.id, t.object_id FROM #{q.call(table)} t
      WHERE t.is_active AND t.is_actual AND t.full_#{hierarchy}_path IS NULL
        AND EXISTS (SELECT 1 FROM #{q.call(hierarchy_table)} h WHERE h.object_id = t.object_id AND h.is_active)
        AND EXISTS (SELECT 1 FROM #{q.call(hierarchy_table)} h JOIN #{q.call(:address_objects)} a ON a.object_id = ANY(string_to_array(h.path, '.')::bigint[])
                    WHERE h.object_id = t.object_id AND h.is_active AND a.is_active AND a.is_actual)
    SQL
    report.call("#{table}: #{hierarchy}_path_ids не совпадает с PATH иерархии", <<~SQL)
      SELECT t.id, t.object_id, t.#{hierarchy}_path_ids, h.path FROM #{q.call(table)} t
      JOIN #{q.call(hierarchy_table)} h ON h.object_id = t.object_id AND h.is_active
      WHERE t.is_active AND t.#{hierarchy}_path_ids IS DISTINCT FROM string_to_array(h.path, '.')::bigint[]
        AND NOT EXISTS (SELECT 1 FROM #{q.call(hierarchy_table)} o WHERE o.object_id = t.object_id AND o.is_active AND o.id <> h.id)
    SQL
  end
  report.call("#{table}: объекты с несколькими действующими актуальными записями", <<~SQL)
    SELECT object_id, count(*) FROM #{q.call(table)} WHERE is_active AND is_actual GROUP BY object_id HAVING count(*) > 1
  SQL
end

puts "== Пересчёт путей и рангов с нуля (#{check})"
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
conn.exec("DROP SCHEMA IF EXISTS #{Gar::Schema.quote(check)} CASCADE")
conn.exec("CREATE SCHEMA #{Gar::Schema.quote(check)}")
begin
  conn.exec("CREATE TABLE #{q.call(Gar::Meta::TABLE, check)} AS SELECT * FROM #{q.call(Gar::Meta::TABLE)}")
  conn.exec("UPDATE #{q.call(Gar::Meta::TABLE, check)} SET status = '#{Gar::Meta::IMPORTED}'")
  tables.each do |table|
    # Пути и ранги (производные колонки, кроме вычисляемых) — пустые: их строит PathBuilder
    reset   = table.derived.reject { _1.type.to_s.include?("GENERATED") }
    copied  = table.copy_columns.map { Gar::Schema.quote(_1.name) }
    columns = [*copied, *reset.map { Gar::Schema.quote(_1.name) }].join(", ")
    values  = [*copied, *reset.map { |column| "NULL::#{column.type}" }].join(", ")
    conn.exec(table.create_sql(check))
    conn.exec("INSERT INTO #{q.call(table.name, check)} (#{columns}) SELECT #{values} FROM #{q.call(table.name)}")
    table.index_sqls(check).each { conn.exec(_1) }
    conn.exec("ANALYZE #{q.call(table.name, check)}")
  end
  Gar.configuration.logger = Logger.new($stderr, level: :warn)
  Gar::PathBuilder.new(conn, schema: check).build
  puts format("  пересчёт: %.1f с", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)

  paths.each do |table|
    columns = [*hiers.keys.flat_map { ["full_#{_1}_path", "#{_1}_path_ids"] }, *(["house_count", "is_capital"] if table == :address_objects)]
    columns.each do |column|
      report.call("#{table}.#{column}: отличается от пересчёта", <<~SQL)
        SELECT a.id, a.object_id, a.#{column} AS было, b.#{column} AS пересчёт FROM #{q.call(table)} a
        JOIN #{q.call(table, check)} b ON b.id = a.id WHERE a.#{column} IS DISTINCT FROM b.#{column}
      SQL
    end
  end
ensure
  conn.exec("DROP SCHEMA IF EXISTS #{Gar::Schema.quote(check)} CASCADE")
  conn.close
end

puts failed ? "Есть расхождения" : "Расхождений нет"
exit(failed ? 1 : 0)
