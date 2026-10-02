#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Download GAR delta updates

require "gar"

# Отключить SSL верификацию
Gar.configure do |config|
  config.api_ssl_verify = false
end

puts "Скачивание дельта обновлений GAR"
puts "=" * 50

begin
  downloader = Gar::Downloader.new

  puts "Получение информации о последней версии..."
  latest = downloader.latest_version

  puts "Версия #{latest['VersionId']} (#{latest['Date']&.split('T')&.first})"
  puts "Описание: #{latest['TextVersion']}"
  puts ""

  if latest["GarXMLDeltaURL"]
    puts "URL: #{latest['GarXMLDeltaURL']}"
    puts "Директория: #{Gar.configuration.delta_dir}"
    puts ""

    puts "Скачивание..."
    zip_path = downloader.download_delta(latest, on_progress: ->(done, total, _) { print "\r#{done}/#{total}" })
    puts "✓ ZIP файл скачан: #{zip_path}"
  else
    puts "✗ Дельта обновления недоступны для этой версии"
    puts ""
    puts "ℹ️  Для некоторых версий дельта обновления могут быть недоступны."
    puts "   В этом случае используйте полную базу данных."
  end
rescue StandardError => e
  puts "Ошибка: #{e.message}"
end
