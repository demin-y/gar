# frozen_string_literal: true

require_relative "parser"

module Gar
  module Entities
    module AddressObjectTypes
      SCHEMA = <<-SQL
        CREATE TABLE IF NOT EXISTS %s (
          id INTEGER PRIMARY KEY,
          level INTEGER NOT NULL,
          short_name VARCHAR(50),
          name VARCHAR(250) NOT NULL,
          "desc" VARCHAR(250),
          update_date DATE,
          start_date DATE,
          end_date DATE,
          is_active BOOLEAN DEFAULT true
        )
      SQL

      INDEXES = [
        "CREATE INDEX IF NOT EXISTS idx_address_object_types_level ON %s(level)",
        "CREATE INDEX IF NOT EXISTS idx_address_object_types_name ON %s(name)"
      ].freeze

      PARSER_CLASS = Entities::AddressObjectTypes::Parser
      XML_KEY = "AS_ADDR_OBJ_TYPES"
    end
  end
end
