#!/usr/bin/env ruby
# frozen_string_literal: true

# Импорт последнего скачанного архива с нужными субъектами в новую схему gar_v<версия>
# (Gar.import). Текущую схему импорт не трогает: поиск работает по ней, пока новая не готова.
#
#   GAR_REGIONS=43,11 GAR_DATABASE_URL=postgresql://… bundle exec ruby examples/2_import_full_base.rb

require_relative "example_helper"

schema = Gar.import(on_progress: progress)
if schema == Gar.configuration.database_schema
  puts "Текущая схема #{schema} уже загружена из этой выгрузки с теми же настройками"
else
  puts "Загружена схема #{schema}. Дальше: examples/3_populate_full_paths.rb #{schema}"
end
