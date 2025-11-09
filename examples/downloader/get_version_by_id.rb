#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Get information about a specific GAR version

require "gar"

puts "Получение информации о конкретной версии GAR"
puts "=" * 50

begin
  downloader = Gar::Downloader.new

  # Получить ID последней версии для примера
  latest = downloader.latest_version
  version_id = latest["VersionId"]

  puts "Запрашиваем информацию о версии #{version_id}..."
  puts ""

  version_info = downloader.version_info(version_id)

  puts "Информация о версии #{version_info['VersionId']}:"
  puts "  Дата создания: #{version_info['Date']&.split('T')&.first}"
  puts "  Описание: #{version_info['TextVersion']}"
  puts ""
  puts "  Доступные файлы:"
  puts "    Полная БД: #{version_info['GarXMLFullURL'] ? '✓ Доступна' : '✗ Недоступна'}"
  puts "    Дельта: #{version_info['GarXMLDeltaURL'] ? '✓ Доступна' : '✗ Недоступна'}"

  if version_info["GarXMLFullURL"]
    puts ""
    puts "  URL полной базы:"
    puts "  #{version_info['GarXMLFullURL']}"
  end

  if version_info["GarXMLDeltaURL"]
    puts ""
    puts "  URL дельта обновлений:"
    puts "  #{version_info['GarXMLDeltaURL']}"
  end
rescue Gar::Error => e
  puts "Ошибка версии: #{e.message}"
rescue StandardError => e
  puts "Ошибка: #{e.message}"
end
