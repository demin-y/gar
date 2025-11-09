# frozen_string_literal: true

module Gar
  module Utils
    def self.full_table_name(table_name, schema_name: Gar.configuration.database_schema)
      schema_name ? "#{schema_name}.#{table_name}" : table_name
    end
  end
end
