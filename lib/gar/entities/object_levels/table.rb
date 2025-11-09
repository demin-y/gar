# frozen_string_literal: true

require_relative "parser"

module Gar
  module Entities
    module ObjectLevels
      SCHEMA = <<-SQL
        CREATE TABLE IF NOT EXISTS %s (
          level INTEGER PRIMARY KEY,
          name VARCHAR(250) NOT NULL,
          update_date DATE,
          start_date DATE,
          end_date DATE,
          is_active BOOLEAN DEFAULT true
        )
      SQL

      INDEXES = [
        "CREATE INDEX IF NOT EXISTS idx_object_levels_name ON %s(name)"
      ].freeze

      PARSER_CLASS = Entities::ObjectLevels::Parser
      XML_KEY = "AS_OBJECT_LEVELS"
    end
  end
end
