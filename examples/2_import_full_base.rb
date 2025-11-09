#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Import full GAR database with duplicate schema creation

require "gar"

Gar.configure do |config|
  config.batch_size              = 10_000
  config.parallel_import         = true
  config.parallel_import_workers = 8

  # Настройка сущностей для импорта (по умолчанию все сущности)
  # Можно задать только необходимые сущности для импорта
  config.import_entities = [
    :object_levels,
    :address_object_types,
    :address_objects,
    :house_types,
    :houses,
    :adm_hierarchy,
    :mun_hierarchy
  ]

  # Настройка параметров импорта для отдельных сущностей
  # entity_options содержит настройки для каждой сущности отдельно
  config.entity_options = {
    address_objects: {
      is_actual: true,
      is_active: true
    },
    houses:          {
      is_actual: true,
      is_active: true
    },
    adm_hierarchy:   {
      is_active: true
    },
    mun_hierarchy:   {
      is_active: true
    },
    reestr_objects:  {
      level:     [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
      is_active: true
    }
  }
end

puts "Импорт полной базы данных GAR с созданием дублирующей схемы"
puts "=" * 65

begin
  # Создаём импортёр данных GAR
  importer = Gar::Importer.new

  # Ищем последний скачанный ZIP файл
  puts "Поиск последнего скачанного ZIP файла..."
  zip_path = importer.find_latest_full_base_zip

  if zip_path.nil?
    puts "⚠️  ZIP файлы не найдены в #{Gar.configuration.full_base_dir}"
    exit 1
  end

  puts "Найден последний ZIP файл: #{File.basename(zip_path)}"
  puts "Путь: #{zip_path}"
  puts "Размер: #{File.size(zip_path)} bytes"
  puts "Дата модификации: #{File.mtime(zip_path)}"
  puts ""

  # Импортируем полную базу с созданием дублирующей схемы
  # Информация о версии будет автоматически извлечена из архива
  puts "Начинаем импорт..."
  schema_name = importer.import_full_base(zip_path)

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
