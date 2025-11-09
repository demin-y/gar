#!/usr/bin/env ruby
# frozen_string_literal: true

require "gar"

# Пример использования поиска по ГАР
#
# Поиск использует двухфазную стратегию для address_objects:
#   Фаза 1: поиск по name (быстрый, использует GIN-индекс idx_address_objects_fulltext)
#   Фаза 2: дополнение из full_path через stored tsvector (если результатов фазы 1 недостаточно)
#
# Ранжирование учитывает уровень объекта: регионы > города > улицы

search = Gar::Search.new

puts "\n=== Примеры поиска адресов ===\n"

# 1. Полнотекстовый поиск address_objects
# Двухфазный: сначала по name (город "Москва" будет первым), затем по full_path
puts "1. Поиск 'Москва' (город ранжируется выше улиц благодаря level-based ranking):"
results = search.search_address_objects("Москва", limit: 10)
results.each do |result|
  puts "  - [level #{result.level}] #{result.full_adm_path}"
end

puts "\n2. Поиск 'Ленина ул' (фаза 1 найдёт по name, фаза 2 дополнит из full_path):"
results = search.search_address_objects("Ленина ул", limit: 10)
results.each do |result|
  puts "  - [level #{result.level}] #{result.full_adm_path}"
end

# 2. Автодополнение (prefix-поиск с :* к последнему слову)
puts "\n3. Автодополнение 'Моск':"
results = search.search_address_objects("Моск", autocomplete: true, limit: 5)
results.each do |result|
  puts "  - #{result.full_adm_path}"
end

# 3. Поиск по муниципальной иерархии
puts "\n4. Поиск по муниципальной иерархии (path_type: :mun):"
results = search.search_address_objects("Тверь", path_type: :mun, limit: 3)
results.each do |result|
  puts "  - #{result.full_mun_path}"
end

# 4. Каскадный поиск по уровням (иерархическая навигация)
puts "\n5. Каскадный поиск - регионы → города → улицы → дома:"
regions = search.find_address_objects(limit: 3)
regions.each do |region|
  puts "  - #{region.name} #{region.type_name}"

  cities = search.find_address_objects(parent_guid: region.object_guid, limit: 2)
  cities.each do |city|
    puts "    - #{city.name} #{city.type_name}"

    streets = search.find_address_objects(parent_guid: city.object_guid, limit: 1)
    streets.each do |street|
      puts "      - #{street.name} #{street.type_name}"

      houses = search.find_houses(street.object_guid, limit: 2)
      houses.each do |house|
        puts "        - #{house.house_type} #{house.house_num}"
      end
    end
  end
end

# 5. Полнотекстовый поиск домов (stored tsvector на 34M строк)
puts "\n6. Поиск домов (stored tsvector):"
house_results = search.search_houses("Тверь д. 110", limit: 3)
house_results.each do |house|
  puts "  - #{house.full_adm_path}"
end

# 6. Поиск по GUID
puts "\n7. Поиск по GUID:"
if regions.any?
  region_guid = regions.first.object_guid
  found_region = search.find_address_object_by_guid(region_guid)
  puts "  Найден: #{found_region.name} #{found_region.type_name}" if found_region
  puts "  Путь: #{found_region.full_adm_path}" if found_region
end

puts "\n=== Завершено ===\n"
