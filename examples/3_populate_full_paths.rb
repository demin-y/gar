#!/usr/bin/env ruby
# frozen_string_literal: true

# Построение полных адресных путей (Gar::PathBuilder) в импортированной схеме.
#
# Заполняет full_adm_path/full_mun_path и их tsvector у address_objects и houses и строит
# полнотекстовые индексы. Пути строятся по загруженным иерархиям. Прерванное построение
# продолжается повторным запуском: заполняются только пустые пути.
#
# Требования: PostgreSQL запущен (make dev-db-up), архив импортирован (2_import_full_base.rb).
#
#   ./examples/3_populate_full_paths.rb [схема]   # по умолчанию — схема последнего скачанного архива

require "gar"

schema = ARGV[0]
unless schema
  zip_path = Gar::Importer.find_latest_full_base_zip
  abort "ZIP файлы не найдены в #{Gar.configuration.full_base_dir}" unless zip_path

  schema = "gar_v#{Gar::Archive.new(zip_path).version_id}"
end

puts "Построение путей в схеме #{schema}"
progress =
  lambda do |done, total, _stage|
    print "\r  #{done}/#{total} (#{total.zero? ? 100 : done * 100 / total}%)"
  end

begin
  count = Gar::PathBuilder.new(schema:).build(on_progress: progress)
  puts "\nГотово: заполнено путей — #{count}"
rescue PG::Error, Gar::Error => e
  abort "\nОшибка: #{e.message}"
end
