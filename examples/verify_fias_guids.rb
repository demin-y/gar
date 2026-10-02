#!/usr/bin/env ruby
# frozen_string_literal: true

# Проверка, что GUID улиц из старых данных (AOGUID ФИАС) — это OBJECTGUID ГАР (Т10):
#
#   GAR_DATABASE_URL=postgresql://… ruby examples/verify_fias_guids.rb streets.csv > report.tsv
#
# Вход — текстовый файл (CSV с любым разделителем), в каждой строке GUID улицы и, желательно,
# её старое название: «0a1b…;ул. Ленина;Киров». Первый GUID строки — проверяемый, остальной
# текст строки — для сравнения с названием в ГАР. Строки без GUID пропускаются.
#
# Выход (stdout) — TSV: GUID, итог, OBJECTID, уровень, название с типом, путь, исходная строка.
# Итоги: «совпадает» (название ГАР есть в строке), «другое название» (GUID найден, названия в
# строке нет: переименование или чужой GUID — смотреть глазами), «недействует» (объект
# упразднён), «не найден». Сводка — в stderr. Схема — config.database_schema.

require "bundler/setup"
require "gar"

GUID  = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
BATCH = 1000

path = ARGV.first or abort("Укажите файл: #{$PROGRAM_NAME} streets.csv")
rows =
  File.foreach(path, chomp: true).filter_map do |line|
    line = line.encode("UTF-8", invalid: :replace, undef: :replace).delete_prefix("\uFEFF")
    guid = line[GUID] or next
    [guid, line]
  end

# Название совпадает, если каждое его слово (или синоним: «Большая» — «Б.») есть в строке
def status(object, line, synonyms)
  return "не найден" unless object
  return "недействует" unless object.active

  words = Gar::Synonyms.words(line).to_set
  same  = Gar::Synonyms.words(object.name).all? { |word| synonyms.variants(word).any? { words.include?(_1) } }
  same ? "совпадает" : "другое название"
end

def cell(value) = value.to_s.tr("\t\n", "  ")

search   = Gar::Search.new
synonyms = search.synonyms
totals   = Hash.new(0)
puts ["guid", "итог", "objectid", "уровень", "название", "путь", "строка"].join("\t")
rows.each_slice(BATCH) do |batch|
  found = search.find_address_objects_by_guids(batch.map(&:first))
  batch.each do |guid, line|
    object = found[guid]
    result = status(object, line, synonyms)
    totals[result] += 1
    puts [guid, result, object&.gar_object_id, object&.level, object && "#{object.name} #{object.type_name}",
          object&.full_adm_path, line].map { cell(_1) }.join("\t")
  end
end

warn "Строк с GUID: #{rows.size}"
totals.sort_by { -_2 }.each { |result, count| warn format("  %<result>-16s %<count>d", result:, count:) }
