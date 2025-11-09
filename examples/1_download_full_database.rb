#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Download full GAR database

require "gar"

# Отключить SSL верификацию для API
Gar.configure do |config|
  config.api_ssl_verify = false
end

puts "Скачивание полной базы данных GAR"
puts "=" * 50

begin
  downloader = Gar::Downloader.new

  puts "Получение информации о последней версии..."
  latest = downloader.latest_version

  puts "Версия #{latest['VersionId']} (#{latest['Date']&.split('T')&.first})"
  puts "Описание: #{latest['TextVersion']}"
  puts ""

  if latest["GarXMLFullURL"]
    puts "URL: #{latest['GarXMLFullURL']}"
    puts "Директория: #{Gar.configuration.full_base_dir}"
    puts ""

    puts "Скачивание..."
    zip_path = downloader.download_full_base(latest, show_progress: true)
    puts "✓ ZIP файл скачан: #{zip_path}"
  else
    puts "✗ Полная база недоступна для этой версии"
  end
rescue StandardError => e
  puts "Ошибка: #{e.message}"
end
