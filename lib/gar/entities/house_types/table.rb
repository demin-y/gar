# frozen_string_literal: true

require_relative "parser"

module Gar
  module Entities
    module HouseTypes
      SCHEMA = <<-SQL
        CREATE TABLE IF NOT EXISTS %s (
          id INTEGER PRIMARY KEY,
          name VARCHAR(50) NOT NULL,
          short_name VARCHAR(20),
          "desc" VARCHAR(250),
          update_date DATE,
          start_date DATE,
          end_date DATE,
          is_active BOOLEAN DEFAULT true
        )
      SQL

      INDEXES = [
        "CREATE INDEX IF NOT EXISTS idx_house_types_name ON %s(name)"
      ].freeze

      PARSER_CLASS = Entities::HouseTypes::Parser
      XML_KEY = "AS_HOUSE_TYPES"
    end
  end
end
