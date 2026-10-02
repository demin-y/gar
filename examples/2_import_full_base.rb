#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Import full GAR database with duplicate schema creation

require "gar"

Gar.configure do |config|
  config.parallel_import         = true
  config.parallel_import_workers = 8

  # Состав данных: набор :minimal (по умолчанию), :extended или :full.
  # Справочники корня архива грузятся всегда.
  config.preset = :minimal

  # Тонкая настройка поверх набора
  # config.tables      += [:steads, :stead_params]  # добавить таблицы субъекта
  # config.hierarchies  = [:adm]                    # только административная иерархия
  # config.param_types  = [5, 7]                    # почтовый индекс и ОКТМО
  # config.keep_history = true                      # хранить неактуальные записи
end

puts "Импорт полной базы данных GAR с созданием дублирующей схемы"
puts "=" * 65

begin
  # Создаём импортёр данных GAR
  importer = Gar::Importer.new

  # Ищем последний скачанный ZIP файл
  puts "Поиск последнего скачанного ZIP файла..."
  zip_path = Gar::Importer.find_latest_full_base_zip

  if zip_path.nil?
    puts "⚠️  ZIP файлы не найдены в #{Gar.configuration.full_base_dir}"
    exit 1
  end

  puts "Найден последний ZIP файл: #{File.basename(zip_path)}"
  puts "Путь: #{zip_path}"
  puts "Размер: #{File.size(zip_path)} bytes"
  puts "Дата модификации: #{File.mtime(zip_path)}"
  puts ""

  # Импортируем базу в схему gar_v<версия>; версия берётся из version.txt внутри архива.
  # region_codes — только папки нужных субъектов (по умолчанию все)
  puts "Начинаем импорт..."
  schema_name = importer.import_full_base(zip_path, region_codes: ["43", "11"])

  puts ""
  puts "🎉 Импорт завершен!"
  puts "Новая схема: #{schema_name}"
  puts ""
  puts "Для переключения на новую версию базы данных используйте метод switch_to_imported_schema:"
  puts "  importer.switch_to_imported_schema('#{schema_name}')"
rescue StandardError => e
  puts "Ошибка: #{e.message}"
  puts ""
  puts "Возможные причины:"
  puts "  - PostgreSQL сервер недоступен"
  puts "  - Недостаточно прав для создания баз данных"
  puts "  - Недостаточно места на диске"
  puts "  - Поврежденный ZIP файл"
end
