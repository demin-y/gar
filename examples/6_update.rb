#!/usr/bin/env ruby
# frozen_string_literal: true

# Обновление до последней выгрузки (Gar.update!) — то, что запускает крон: дельты новее текущей
# версии или, если базы нет, изменились настройки, цепочка прервана или подошёл
# full_import_interval, — полный импорт с путями и переключением.
#
#   GAR_REGIONS=43,11 GAR_DATABASE_URL=postgresql://… bundle exec ruby examples/6_update.rb

require_relative "example_helper"

before = Gar.current_version&.version_id
result = Gar.update!(on_progress: progress)
case result.kind
when :none  then puts "ГАР актуален: версия #{result.to_version}"
when :delta then puts "Применены дельты #{result.versions.join(', ')}: #{before} → #{result.to_version}"
else puts "Полный импорт (#{result.reason}): #{before || '—'} → #{result.to_version}"
end
Gar.status.updates.first(3).each { puts "  дельта #{_1.version_id}: +#{_1.upserted} −#{_1.deleted}, #{_1.applied_at}" }
