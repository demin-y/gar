#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Cleanup old ZIP files

require "gar"

puts "Очистка старых ZIP файлов GAR"
puts "=" * 40

# Отключить SSL верификацию
Gar.configure do |config|
  config.api_ssl_verify = false
end

downloader = Gar::Downloader.new

puts "Примеры использования cleanup_old_files:"
puts ""

# Пример 1: Dry run - показать что будет удалено
puts "1. Dry run - анализ файлов для удаления:"
puts "-" * 40
downloader.cleanup_old_files(dry_run: true)

puts ""

# Пример 2: Очистка с кастомными настройками
puts "2. Очистка с настройками (сохранить 3 версии, файлы старше 7 дней):"
puts "-" * 60
# downloader.cleanup_old_files(keep_versions: 3, keep_days: 7, dry_run: true)

puts ""

# Пример 3: Очистка конкретной директории
puts "3. Очистка конкретной директории:"
puts "-" * 35
# downloader.cleanup_old_files(directory: './my_custom_dir', dry_run: true)

puts ""
puts "⚠️  Для реальной очистки установите dry_run: false"
puts ""
puts "Пример:"
puts "  downloader.cleanup_old_files(keep_versions: 3, keep_days: 30)"
