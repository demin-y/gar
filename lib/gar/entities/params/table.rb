# frozen_string_literal: true

require_relative "parser"

module Gar
  module Entities
    module Params
      SCHEMA = <<-SQL
        CREATE TABLE IF NOT EXISTS %s (
          id BIGINT PRIMARY KEY,
          object_id BIGINT NOT NULL,
          change_id BIGINT,
          change_id_end BIGINT,
          type_id INTEGER NOT NULL,
          value TEXT,
          update_date DATE,
          start_date DATE,
          end_date DATE
        )
      SQL

      INDEXES = [
        "CREATE INDEX IF NOT EXISTS idx_params_object_id ON %s(object_id)",
        "CREATE INDEX IF NOT EXISTS idx_params_type_id ON %s(type_id)"
      ].freeze

      PARSER_CLASS = Entities::Params::Parser
      XML_KEY = "AS_PARAM"
    end
  end
end
