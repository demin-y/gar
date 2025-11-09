# frozen_string_literal: true

require_relative "parser"

module Gar
  module Entities
    module AdmHierarchy
      SCHEMA = <<-SQL
        CREATE TABLE IF NOT EXISTS %s (
          id BIGINT PRIMARY KEY,
          object_id BIGINT NOT NULL,
          parent_obj_id BIGINT,
          change_id BIGINT,
          region_code VARCHAR(4),
          area_code VARCHAR(4),
          city_code VARCHAR(4),
          place_code VARCHAR(4),
          plan_code VARCHAR(4),
          street_code VARCHAR(4),
          prev_id BIGINT,
          next_id BIGINT,
          update_date DATE,
          start_date DATE,
          end_date DATE,
          is_active BOOLEAN DEFAULT true,
          path TEXT
        )
      SQL

      INDEXES = [
        "CREATE INDEX IF NOT EXISTS idx_adm_hierarchy_object_id ON %s(object_id)",
        "CREATE INDEX IF NOT EXISTS idx_adm_hierarchy_object_id_active ON %s(object_id) WHERE is_active = true",
        "CREATE INDEX IF NOT EXISTS idx_adm_hierarchy_parent_obj_id ON %s(parent_obj_id)"
      ].freeze

      PARSER_CLASS = Entities::AdmHierarchy::Parser
      XML_KEY = "AS_ADM_HIERARCHY"
    end
  end
end
