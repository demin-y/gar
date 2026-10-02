# frozen_string_literal: true

module Gar
  module Utils
    SIZE_UNITS = ["Б", "КБ", "МБ", "ГБ", "ТБ"].freeze

    def self.full_table_name(table_name, schema_name: Gar.configuration.database_schema)
      schema_name ? "#{schema_name}.#{table_name}" : table_name
    end

    # Размер для логов: 1536 → «1.5 КБ»
    def self.format_size(bytes)
      bytes = bytes.to_i
      exp   = bytes < 1024 ? 0 : [(Math.log(bytes) / Math.log(1024)).to_i, SIZE_UNITS.size - 1].min
      exp.zero? ? "#{bytes} Б" : "#{(bytes / (1024.0**exp)).round(1)} #{SIZE_UNITS[exp]}"
    end
  end
end
