#!/usr/bin/env ruby
# frozen_string_literal: true

# Переключение на готовую схему (Gar.switch): она становится текущей (config.database_schema),
# прежняя текущая — резервной, лишние резервные удаляются. То же в Rails — rake "gar:switch[…]".
#
#   GAR_DATABASE_URL=postgresql://… bundle exec ruby examples/4_switch_to_imported_schema.rb gar_v20261002

require_relative "example_helper"

schema = ARGV[0] or abort "Укажите схему: #{$PROGRAM_NAME} gar_v<версия> (её имя печатает 2_import_full_base.rb)"
Gar.switch(schema, on_progress: progress)
meta = Gar.current_version
puts "Схема #{schema} стала текущей (#{Gar.configuration.database_schema}): версия #{meta.version_id}, субъекты #{meta.region_codes.join(', ')}"
