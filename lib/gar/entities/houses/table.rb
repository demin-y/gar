# frozen_string_literal: true

require_relative "parser"

module Gar
  module Entities
    module Houses
      SCHEMA = <<-SQL
        CREATE TABLE IF NOT EXISTS %s (
          id BIGINT PRIMARY KEY,
          object_id BIGINT NOT NULL,
          object_guid VARCHAR(36),
          change_id BIGINT,
          house_num VARCHAR(50),
          house_type INTEGER,
          oper_type_id INTEGER,
          prev_id BIGINT,
          next_id BIGINT,
          update_date DATE,
          start_date DATE,
          end_date DATE,
          is_actual BOOLEAN DEFAULT true,
          is_active BOOLEAN DEFAULT true
        )
      SQL

      INDEXES = [
        "CREATE INDEX IF NOT EXISTS idx_houses_object_id ON %s(object_id)",
        "CREATE INDEX IF NOT EXISTS idx_houses_house_num ON %s(house_num)",
        "CREATE INDEX IF NOT EXISTS idx_houses_fulltext ON %s USING gin(to_tsvector('russian', house_num)) WHERE is_active = true"
      ].freeze

      PARSER_CLASS = Entities::Houses::Parser
      XML_KEY = "AS_HOUSES"

      def self.table_name
        "houses"
      end

      def self.column_name
        "path"
      end

      def self.column_type
        "TEXT"
      end
    end
  end
end
