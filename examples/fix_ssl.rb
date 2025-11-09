#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick fix for SSL certificate issues

require "gar"

puts "Исправление проблем с SSL сертификатами"
puts "=" * 50

# Отключить SSL верификацию
Gar.configure do |config|
  config.api_ssl_verify = false
end

puts "✓ SSL верификация отключена"
puts "Теперь можно использовать все функции загрузки без ошибок SSL"
puts ""

# Тестирование
puts "Тестирование подключения..."
begin
  downloader = Gar::Downloader.new
  versions = downloader.get_all_versions
  puts "✓ Подключение к FIAS API работает!"
  puts "  Доступно #{versions.length} версий данных"
rescue StandardError => e
  puts "✗ Ошибка подключения: #{e.message}"
end

puts ""
puts "Теперь можно запускать:"
puts "  ./examples/downloader/download_full_base.rb"
puts "  ./examples/downloader/get_all_versions.rb"
puts "  и другие скрипты загрузки"
