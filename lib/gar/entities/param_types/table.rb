# frozen_string_literal: true

require_relative "parser"

module Gar
  module Entities
    module ParamTypes
      SCHEMA = <<-SQL
        CREATE TABLE IF NOT EXISTS %s (
          id INTEGER PRIMARY KEY,
          name VARCHAR(50) NOT NULL,
          code VARCHAR(50),
          "desc" VARCHAR(120),
          update_date DATE,
          start_date DATE,
          end_date DATE,
          is_active BOOLEAN DEFAULT true
        )
      SQL

      INDEXES = [
        "CREATE INDEX IF NOT EXISTS idx_param_types_code ON %s(code)",
        "CREATE INDEX IF NOT EXISTS idx_param_types_name ON %s(name)"
      ].freeze

      PARSER_CLASS = Entities::ParamTypes::Parser
      XML_KEY = "AS_PARAM_TYPES"
    end
  end
end
