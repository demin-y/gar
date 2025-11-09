#!/usr/bin/env ruby
# frozen_string_literal: true

# Пример использования Gar::FullPathBuilder для заполнения полных путей адресов и домов
#
# Этот пример демонстрирует:
# 1. Добавление колонок full_adm_path и full_mun_path
# 2. Заполнение полных путей для объектов адресации (address_objects)
# 3. Заполнение полных путей для домов (houses)
# 4. Создание полнотекстового индекса
#
# Требования:
# 1. PostgreSQL должен быть запущен: make dev-db-up
# 2. База данных должна содержать импортированные данные ГАР
# 3. Таблицы address_objects, houses, adm_hierarchy, mun_hierarchy должны существовать

require "gar"

importer = Gar::Importer.new

# Ищем последний скачанный ZIP файл
puts "Поиск последнего скачанного ZIP файла..."
zip_path = importer.find_latest_full_base_zip

if zip_path.nil?
  puts "⚠️  ZIP файлы не найдены в #{Gar.configuration.full_base_dir}"
  exit 1
end

version     = importer.extract_version_from_archive(zip_path)
schema_name = "gar_v#{version}"

puts "✓ Найден ZIP файл: #{File.basename(zip_path)}"
puts "  Версия: #{version}"
puts "  Схема БД: #{schema_name}"

Gar.configure do |config|
  config.database_schema = schema_name
end

# Проверка подключения к БД
begin
  db_conn = Gar::Database.connection
  db_conn.exec("SELECT 1")
  puts "✓ Подключение к БД успешно"
  puts "  Database: #{Gar.configuration.database_url}"
  puts ""
rescue PG::ConnectionBad => e
  puts "✗ Не удалось подключиться к PostgreSQL"
  puts "  Ошибка: #{e.message}"
  puts ""
  puts "Запустите БД командой: make dev-db-up"
  exit 1
end

builder = Gar::FullPathBuilder.new

puts ""
puts "Обновление полных путей для address_objects и houses"
puts "=" * 65

begin
  builder.update_address_objects_paths
rescue PG::ConnectionBad => e
  puts "✗ Ошибка подключения к БД: #{e.message}"
  puts ""
  puts "Убедитесь что PostgreSQL запущен:"
  puts "  make dev-db-up"
  puts ""
  puts "Проверьте connection string:"
  puts "  #{Gar.configuration.database_url}"
  exit 1
rescue StandardError => e
  puts "✗ Ошибка: #{e.message}"
  puts e.backtrace.first(5).join("\n")
end

begin
  builder.update_houses_paths
rescue PG::ConnectionBad => e
  puts "✗ Ошибка подключения к БД: #{e.message}"
  puts ""
  puts "Убедитесь что PostgreSQL запущен:"
  puts "  make dev-db-up"
  puts ""
  puts "Проверьте connection string:"
  puts "  #{Gar.configuration.database_url}"
  exit 1
rescue StandardError => e
  puts "✗ Ошибка: #{e.message}"
  puts e.backtrace.first(5).join("\n")
end

puts "🎉 Импорт завершен!"
