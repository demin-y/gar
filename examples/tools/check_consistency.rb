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
# 2. Пересчёт с нуля: таблицы копируются в схему <схема>_consistency без путей и рангов,
#    PathBuilder строит их заново, и они сравниваются с проверяемой схемой по id записи.
#
# Печатает число расхождений по каждой проверке и до 5 примеров; код выхода 1, если они есть.
# Схема по умолчанию — config.database_schema. <схема>_consistency создаётся и удаляется
# скриптом; если такая схема уже есть, скрипт её не трогает и останавливается.

require_relative "support"

schema  = ARGV[0] || Gar.configuration.database_schema
check   = "#{schema}_consistency"
conn    = Gar::Database.create_connection
meta    = Gar::Meta.read(conn, schema) or abort("В схеме #{schema} нет gar_meta")
builder = Gar::PathBuilder.new(conn, schema:)
q       = ->(name, in_schema = schema) { Gar::Schema.qualify(in_schema, name) }
loaded  = Gar::Database.existing_relations(conn, meta.tables.map { q.call(_1) })
tables  = meta.tables.map { Gar::Schema.fetch(_1) }.select { loaded.include?(q.call(_1.name)) }
hiers   = builder.hierarchies.to_h { [_1, Gar::Configuration::HIERARCHY_TABLES.fetch(_1)] }
report  = GarTools::Report.new(conn)

puts "Схема #{schema}: версия #{meta.version_id}, субъекты #{meta.region_codes.join(', ').then { _1.empty? ? 'все' : _1 }}"
puts "== Инварианты"
builder.tables.each do |table|
  hiers.each do |hierarchy, hierarchy_table|
    report.check("#{table}: действующие без #{hierarchy}-пути при строке иерархии", <<~SQL)
      SELECT t.id, t.object_id FROM #{q.call(table)} t
      WHERE t.is_active AND t.is_actual AND t.full_#{hierarchy}_path IS NULL
        AND EXISTS (SELECT 1 FROM #{q.call(hierarchy_table)} h WHERE h.object_id = t.object_id AND h.is_active)
        AND EXISTS (SELECT 1 FROM #{q.call(hierarchy_table)} h JOIN #{q.call(:address_objects)} a ON a.object_id = ANY(string_to_array(h.path, '.')::bigint[])
                    WHERE h.object_id = t.object_id AND h.is_active AND a.is_active AND a.is_actual)
    SQL
    report.check("#{table}: #{hierarchy}_path_ids не совпадает с PATH иерархии", <<~SQL)
      SELECT t.id, t.object_id, t.#{hierarchy}_path_ids, h.path FROM #{q.call(table)} t
      JOIN #{q.call(hierarchy_table)} h ON h.object_id = t.object_id AND h.is_active
      WHERE t.is_active AND t.#{hierarchy}_path_ids IS DISTINCT FROM string_to_array(h.path, '.')::bigint[]
        AND NOT EXISTS (SELECT 1 FROM #{q.call(hierarchy_table)} o WHERE o.object_id = t.object_id AND o.is_active AND o.id <> h.id)
    SQL
  end
  report.check("#{table}: объекты с несколькими действующими актуальными записями", <<~SQL)
    SELECT object_id, count(*) FROM #{q.call(table)} WHERE is_active AND is_actual GROUP BY object_id HAVING count(*) > 1
  SQL
end

puts "== Пересчёт путей и рангов с нуля (#{check})"
abort("Схема #{check} уже есть: удалите её сами или проверьте другую схему") if Gar::Schemas.exists?(conn, check)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
conn.exec("CREATE SCHEMA #{Gar::Schema.quote(check)}")
begin
  conn.exec("CREATE TABLE #{q.call(Gar::Meta::TABLE, check)} AS SELECT * FROM #{q.call(Gar::Meta::TABLE)}")
  Gar::Meta.update(conn, check, Gar::Meta::IMPORTED)
  tables.each do |table|
    # Только колонки из XML: пути и ранги остаются пустыми (их строит PathBuilder), вычисляемые
    # колонки PostgreSQL считает сам
    columns = table.copy_columns.map { Gar::Schema.quote(_1.name) }.join(", ")
    conn.exec(table.create_sql(check))
    conn.exec("INSERT INTO #{q.call(table.name, check)} (#{columns}) SELECT #{columns} FROM #{q.call(table.name)}")
    table.index_sqls(check).each { conn.exec(_1) }
    conn.exec("ANALYZE #{q.call(table.name, check)}")
  end
  Gar.configuration.logger = Logger.new($stderr, level: :warn)
  Gar::PathBuilder.new(conn, schema: check).build
  puts format("  пересчёт: %.1f с", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)

  builder.tables.each do |table|
    columns = [*hiers.keys.flat_map { ["full_#{_1}_path", "#{_1}_path_ids"] }, *(["house_count", "is_capital"] if table == :address_objects)]
    columns.each do |column|
      report.check("#{table}.#{column}: отличается от пересчёта", <<~SQL)
        SELECT a.id, a.object_id, a.#{column} AS было, b.#{column} AS пересчёт FROM #{q.call(table)} a
        JOIN #{q.call(table, check)} b ON b.id = a.id WHERE a.#{column} IS DISTINCT FROM b.#{column}
      SQL
    end
  end
ensure
  conn.exec("DROP SCHEMA IF EXISTS #{Gar::Schema.quote(check)} CASCADE")
  conn.close
end

report.finish("Расхождений нет")
