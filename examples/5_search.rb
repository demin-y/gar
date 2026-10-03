#!/usr/bin/env ruby
# frozen_string_literal: true

# Поиск по текущей схеме: автодополнение строки адреса, разобранный адрес по GUID, перенос
# старого адреса (дом по GUID улицы и номеру) и методы Gar::Search. Запросы — для субъектов 43
# и 11; свой запрос — аргументом:
#
#   GAR_DATABASE_URL=postgresql://… bundle exec ruby examples/5_search.rb ["Киров, ул. Ленина, д. 10"]

require_relative "example_helper"

abort "База ГАР недоступна или не готова (GAR_DATABASE_URL, gar_meta.status = ready)" unless Gar.available?

puts "== Автодополнение (Gar.autocomplete)"
(ARGV.empty? ? ["Киров, ул. Ленина, д. 10", "Сыктывкар Коммунистическая 33", "Кир", "610000"] : ARGV).each do |query|
  puts "«#{query}»"
  Gar.autocomplete(query, limit: 3).each { puts "  #{_1.kind == :house ? 'дом ' : 'объект'} #{_1.address || _1.name}" }
end

search = Gar::Search.new
house  = Gar.autocomplete("Киров Ленина 10", limit: 1).first or abort "Нет дома «Киров Ленина 10»: в базе нет субъекта 43?"
street = search.search_address_objects("Киров Ленина", limit: 1).first

puts "\n== Адрес по GUID (Gar.address)"
address = Gar.address(house.object_guid)
puts "  #{address.full_address}"
puts "  #{address.short_address}"
puts "  индекс #{address.postal_code}, ОКТМО #{address.oktmo}, субъект #{address.region_code}"

puts "\n== Перенос старого адреса (Gar.match_house)"
["10", "д. 10, кв. 5", "10 лит. А"].each do |number|
  match = Gar.match_house(street_guid: street.object_guid, number:)
  puts "  «#{number}»: #{match.status} #{match.house&.full_adm_path} (альтернатив: #{match.alternatives.size})"
end

puts "\n== Gar::Search"
puts "  в границах города: #{search.find_address_objects(level: 8, within: address.parent_guids[1], limit: 3).map(&:name).join(', ')}"
puts "  дома улицы: #{search.find_houses(street.object_guid, limit: 10).map(&:house_num).join(' ')}"
puts "  по муниципальной иерархии: #{search.search_address_objects('Киров', hierarchy: :mun, limit: 1).first&.full_mun_path}"
