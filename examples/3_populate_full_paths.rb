#!/usr/bin/env ruby
# frozen_string_literal: true

# Построение путей схемы (Gar.build_paths): полные адреса, их полнотекстовые индексы, OBJECTID
# пути и ранги для поиска. Прерванное построение продолжается повторным запуском.
#
#   GAR_DATABASE_URL=postgresql://… bundle exec ruby examples/3_populate_full_paths.rb gar_v20261002

require_relative "example_helper"

schema = ARGV[0] || Gar.configuration.database_schema
count  = Gar.build_paths(schema, on_progress: progress)
puts "Пути схемы #{schema} построены: #{count} записей. Дальше: examples/4_switch_to_imported_schema.rb #{schema}"
