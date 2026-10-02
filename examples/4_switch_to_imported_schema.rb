#!/usr/bin/env ruby
# frozen_string_literal: true

# Переключение на загруженную схему (Gar.switch): она становится текущей (config.database_schema),
# прежняя текущая — резервной, лишние резервные удаляются. Переключить можно только готовую
# схему — после 3_populate_full_paths.rb. То же в Rails — rake "gar:switch[gar_v20260116]".
#
#   ./examples/4_switch_to_imported_schema.rb [схема]   # по умолчанию — схема последнего скачанного архива

require "gar"

schema = ARGV[0]
unless schema
  zip_path = Gar::Importer.find_latest_full_base_zip or abort "ZIP файлы не найдены в #{Gar.configuration.full_base_dir}"
  schema   = Gar::Schemas.import_name(Gar.configuration.database_schema, Gar::Archive.new(zip_path).version_id)
end

begin
  Gar.switch(schema)
  puts "Схема #{schema} стала текущей (#{Gar.configuration.database_schema})"
  puts "Версия: #{Gar.current_version.version_id}"
rescue Gar::Error => e
  abort "Ошибка: #{e.message}"
end
