#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Switch to imported GAR database schema

require "gar"

puts "Переключение на импортированную базу данных GAR"
puts "=" * 50

begin
  # Создаём импортёр данных GAR
  importer = Gar::Importer.new

  # Находим последний скачанный ZIP файл для определения версии
  puts "Поиск последнего скачанного ZIP файла..."
  zip_path = Gar::Importer.find_latest_full_base_zip

  if zip_path.nil?
    puts "⚠️  ZIP файлы не найдены в #{Gar.configuration.full_base_dir}"
    exit 1
  end

  version     = importer.extract_version_from_archive(zip_path)
  schema_name = "gar_v#{version}"

  puts "✓ Найден ZIP файл: #{File.basename(zip_path)}"
  puts "  Версия: #{version}"
  puts "  Схема БД: #{schema_name}"

  puts "Переключение на схему #{schema_name}..."
  importer.switch_to_imported_schema(schema_name)
rescue StandardError => e
  puts "Ошибка: #{e.message}"
  puts ""
  puts "Возможные причины:"
  puts "  - Схема #{schema_name} не существует"
  puts "  - Недостаточно прав на переименование схем"
  puts "  - PostgreSQL сервер недоступен"
end
