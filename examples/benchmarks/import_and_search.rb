#!/usr/bin/env ruby
# frozen_string_literal: true

# Замер импорта и поиска на архиве из generate_archive.rb (или реальном):
#
#   GAR_DATABASE_URL=postgresql://… ruby examples/benchmarks/import_and_search.rb tmp/bench/gar_xml_v20260116.zip
#
# Импортирует архив в отдельную схему (по умолчанию gar_bench; прежняя схема с этим именем
# удаляется), строит пути и выполняет запросы поиска, автодополнения (Gar.autocomplete) и
# адреса (Gar.address), печатая время этапов и p50/p95/max по каждому виду запроса. Субъекты,
# иерархии и параллельность — из настроек гема.

require "bundler/setup"
require "gar"
require "optparse"

options = { schema: "gar_bench", queries: 100, skip_import: false }
OptionParser.new do |parser|
  parser.banner = "Использование: #{$PROGRAM_NAME} АРХИВ.zip [параметры]"
  parser.on("--schema NAME", "Схема для замера (по умолчанию gar_bench, пересоздаётся)") { options[:schema] = _1 }
  parser.on("--queries N", Integer, "Запросов каждого вида (по умолчанию 100)") { options[:queries] = _1 }
  parser.on("--skip-import", "Не импортировать: искать в уже загруженной схеме") { options[:skip_import] = true }
end.parse!
zip_path = ARGV.first or abort("Укажите архив: #{$PROGRAM_NAME} АРХИВ.zip")
schema   = options[:schema]

def measure(title, &)
  puts format("%<title>-28s %<seconds>8.1f с", title:, seconds: timed(&))
end

def percentiles(title, samples)
  sorted = samples.sort
  at     = ->(share) { sorted[((sorted.size - 1) * share).round] * 1000 }
  puts format("%<title>-28s p50 %<p50>6.1f мс  p95 %<p95>6.1f мс  max %<max>6.1f мс  (%<count>d)",
              title:, p50: at.call(0.5), p95: at.call(0.95), max: sorted.last * 1000, count: sorted.size)
end

def timed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

Gar.configuration.logger = Logger.new($stderr, level: :warn)
conn = Gar::Database.create_connection
conn.exec("SET client_min_messages = warning")

unless options[:skip_import]
  conn.exec("DROP SCHEMA IF EXISTS #{Gar::Schema.quote(schema)} CASCADE")
  measure("Импорт") { Gar::Importer.new(conn).import_full_base(zip_path, schema:) }
  measure("Полные пути") { Gar::PathBuilder.new(conn, schema:).build }
end

search   = Gar::Search.new(conn, schema:)
complete = Gar::Autocomplete.new(search)
address  = Gar::AddressBuilder.new(search)
objects  = Gar::Schema.fetch(:address_objects).qualified_name(schema)
# Улица, её город (родитель по административной иерархии), субъект и дом на ней
streets = conn.exec(<<~SQL).map { _1.transform_keys(&:to_sym) }
  SELECT s.object_guid AS guid, s.name, s.region_code AS region, c.object_guid AS city, h.object_guid AS house
  FROM (SELECT * FROM #{objects} WHERE level = 8 AND is_active ORDER BY random() LIMIT #{options[:queries].to_i}) s
  JOIN #{objects} c ON c.object_id = s.adm_path_ids[array_length(s.adm_path_ids, 1) - 1] AND c.is_active
  JOIN LATERAL (SELECT object_guid FROM #{Gar::Schema.fetch(:houses).qualified_name(schema)}
                WHERE adm_path_ids @> ARRAY[s.object_id] AND is_active LIMIT 1) h ON true
SQL
abort("В схеме #{schema} нет улиц с домами") if streets.empty?

queries = {
  "Улица по названию"       => ->(s) { search.search_address_objects(s[:name]) },
  "Улица, автодополнение"   => ->(s) { search.search_address_objects(s[:name][0, 4], autocomplete: true) },
  "Дом: улица и номер"      => ->(s) { search.search_houses("#{s[:name]} 12") },
  "Дома улицы по GUID"      => ->(s) { search.find_houses(s[:guid]) },
  "autocomplete: улица"     => ->(s) { complete.call(s[:name][0, 5], region_codes: [s[:region]]) },
  "autocomplete: улица дом" => ->(s) { complete.call("#{s[:name]} 12", region_codes: [s[:region]]) },
  "autocomplete: в городе"  => ->(s) { complete.call("#{s[:name]} 1", within: s[:city]) },
  "address по GUID дома"    => ->(s) { address.call(s[:house]) }
}
queries.each { |title, query| percentiles(title, streets.map { |street| timed { query.call(street) } }) }
conn.close
