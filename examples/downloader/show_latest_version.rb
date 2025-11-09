#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Get the latest GAR version

require "gar"

puts "Получение последней версии GAR"
puts "=" * 50

begin
  downloader = Gar::Downloader.new
  latest = downloader.latest_version

  puts "Последняя версия:"
  puts "  ID: #{latest['VersionId']}"
  puts "  Дата: #{latest['Date']&.split('T')&.first}"
  puts "  Описание: #{latest['TextVersion']}"
  puts "  Полная БД: #{latest['GarXMLFullURL'] ? 'Доступна' : 'Недоступна'}"
  puts "  Дельта: #{latest['GarXMLDeltaURL'] ? 'Доступна' : 'Недоступна'}"
  puts "  URL полной БД: #{latest['GarXMLFullURL']}" if latest["GarXMLFullURL"]
  puts "  URL дельты: #{latest['GarXMLDeltaURL']}" if latest["GarXMLDeltaURL"]
rescue StandardError => e
  puts "Ошибка: #{e.message}"
end
