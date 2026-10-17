#!/usr/bin/env ruby
# frozen_string_literal: true

# Сравнение двух схем ГАР — например, цепочки дельт с полной выгрузкой той же версии:
#
#   GAR_DATABASE_URL=postgresql://… ruby examples/tools/compare_schemas.rb gar gar_full_v20261002
#
# Для каждой общей таблицы: число записей, записи только в одной схеме и записи с разными
# значениями (по первичному ключу, колонки из XML); для таблиц с путями — адреса (full_*_path
# действующих записей), которые есть только в одной схеме, и число домов адресных объектов.
# Печатает число расхождений и до 5 примеров; код выхода 1, если они есть.

require_relative "support"

left, right = ARGV
abort("Использование: #{$PROGRAM_NAME} схема_1 схема_2") unless left && right

conn   = Gar::Database.create_connection
metas  = [left, right].map { Gar::Meta.read(conn, _1) or abort("В схеме #{_1} нет gar_meta") }
tables = (metas[0].tables & metas[1].tables).map { Gar::Schema.fetch(_1) }
# Обе стороны сравнения: [в этой схеме, нет в той]
sides  = [[left, right], [right, left]]
q      = ->(schema, table) { Gar::Schema.qualify(schema, table) }
report = GarTools::Report.new(conn, indent: "  ")

metas.zip([left, right]).each { |meta, name| puts "#{name}: версия #{meta.version_id}, #{meta.status}, субъекты #{meta.region_codes.join(', ')}" }
tables.each do |table|
  counts = [left, right].map { conn.exec("SELECT count(*) FROM #{q.call(_1, table.name)}").getvalue(0, 0).to_i }
  puts "== #{table.name}: #{counts.join(' / ')}"
  columns = table.copy_columns.map { Gar::Schema.quote(_1.name) }.join(", ")
  if table.primary_key.any?
    key = table.primary_key.map { Gar::Schema.quote(_1) }.join(", ")
    sides.each { |a, b| report.check("только в #{a}", "SELECT #{key} FROM #{q.call(a, table.name)} EXCEPT SELECT #{key} FROM #{q.call(b, table.name)}") }
    report.check("с разными значениями", <<~SQL)
      SELECT #{key} FROM (SELECT #{columns} FROM #{q.call(left, table.name)} EXCEPT SELECT #{columns} FROM #{q.call(right, table.name)}) d
      WHERE (#{key}) IN (SELECT #{key} FROM #{q.call(right, table.name)})
    SQL
  else
    sides.each do |a, b|
      report.check("записи только в #{a}", "SELECT #{columns} FROM #{q.call(a, table.name)} EXCEPT ALL SELECT #{columns} FROM #{q.call(b, table.name)}")
    end
  end
  next unless table.paths?

  Gar::Configuration::HIERARCHY_TABLES.each_key do |hierarchy|
    path = "full_#{hierarchy}_path"
    sides.each do |a, b|
      report.check("#{path} только в #{a}", <<~SQL)
        SELECT #{path} FROM #{q.call(a, table.name)} WHERE is_active AND #{path} IS NOT NULL
        EXCEPT ALL SELECT #{path} FROM #{q.call(b, table.name)} WHERE is_active AND #{path} IS NOT NULL
      SQL
    end
  end
  next unless table.name == :address_objects

  report.check("house_count / is_capital различаются", <<~SQL)
    SELECT a.object_id, a.name, a.house_count, b.house_count, a.is_capital, b.is_capital
    FROM #{q.call(left, :address_objects)} a JOIN #{q.call(right, :address_objects)} b ON b.object_id = a.object_id AND b.is_active AND b.is_actual
    WHERE a.is_active AND a.is_actual AND (a.house_count IS DISTINCT FROM b.house_count OR a.is_capital IS DISTINCT FROM b.is_capital)
  SQL
end
conn.close

report.finish("Схемы совпадают")
