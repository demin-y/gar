# frozen_string_literal: true

require_relative "parser"

module Gar
  module Entities
    module AddressObjects
      SCHEMA = <<-SQL
        CREATE TABLE IF NOT EXISTS %s (
          id BIGINT PRIMARY KEY,
          object_id BIGINT NOT NULL,
          object_guid VARCHAR(36),
          change_id BIGINT,
          name VARCHAR(250),
          type_name VARCHAR(50),
          level INTEGER,
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
        "CREATE INDEX IF NOT EXISTS idx_address_objects_object_id ON %s(object_id)",
        "CREATE INDEX IF NOT EXISTS idx_address_objects_object_id_active ON %s(object_id) WHERE is_active = true",
        "CREATE INDEX IF NOT EXISTS idx_address_objects_name ON %s(name)",
        "CREATE INDEX IF NOT EXISTS idx_address_objects_level ON %s(level)",
        "CREATE INDEX IF NOT EXISTS idx_address_objects_type_name ON %s(type_name)",
        "CREATE INDEX IF NOT EXISTS idx_address_objects_fulltext ON %s USING gin(to_tsvector('russian', name || ' ' || type_name)) WHERE is_active = true",
        "CREATE INDEX IF NOT EXISTS idx_address_objects_level_is_active ON %s(level, is_active)"
      ].freeze

      PARSER_CLASS = Entities::AddressObjects::Parser
      XML_KEY = "AS_ADDR_OBJ"

      def self.table_name
        "address_objects"
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
