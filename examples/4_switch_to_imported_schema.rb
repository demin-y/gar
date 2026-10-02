#!/usr/bin/env ruby
# frozen_string_literal: true

# Переключение на загруженную схему (Gar.switch): она становится текущей (config.database_schema),
# прежняя текущая — резервной, лишние резервные удаляются. Переключить можно только готовую
# схему — после 3_populate_full_paths.rb. То же в Rails — rake "gar:switch[gar_v20260116]".
#
#   ./examples/4_switch_to_imported_schema.rb gar_v20260116   # имя схемы печатает 2_import_full_base.rb

require "gar"

schema = ARGV[0] or abort "Укажите схему: #{$PROGRAM_NAME} gar_v<версия> (её имя печатает 2_import_full_base.rb)"

begin
  Gar.switch(schema)
  puts "Схема #{schema} стала текущей (#{Gar.configuration.database_schema})"
  puts "Версия: #{Gar.current_version.version_id}"
rescue Gar::Error => e
  abort "Ошибка: #{e.message}"
end
