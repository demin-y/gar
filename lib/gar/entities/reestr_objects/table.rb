# frozen_string_literal: true

require_relative "parser"

module Gar
  module Entities
    module ReestrObjects
      SCHEMA = <<-SQL
        CREATE TABLE IF NOT EXISTS %s (
          object_id BIGINT PRIMARY KEY,
          object_guid VARCHAR(36) NOT NULL,
          level_id INTEGER,
          is_active BOOLEAN DEFAULT true,
          created_date DATE,
          updated_date DATE
        )
      SQL

      INDEXES = [
        "CREATE INDEX IF NOT EXISTS idx_reestr_objects_object_id ON %s(object_id)",
        "CREATE INDEX IF NOT EXISTS idx_reestr_objects_object_guid ON %s(object_guid)",
        "CREATE INDEX IF NOT EXISTS idx_reestr_objects_level_id ON %s(level_id)"
      ].freeze

      PARSER_CLASS = Entities::ReestrObjects::Parser
      XML_KEY = "AS_REESTR_OBJECTS"

      # Settings for parser
      DEFAULT_PARSER_OPTIONS = {}.freeze
    end
  end
end
