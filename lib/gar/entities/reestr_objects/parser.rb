# frozen_string_literal: true

require_relative "../base_parser"

module Gar
  module Entities
    module ReestrObjects
      class Parser < BaseParser
        def xml_element_name
          "OBJECT"
        end

        def headers
          [:object_id, :object_guid, :level_id, :is_active, :created_date, :updated_date]
        end

        def record_data_from_attributes(attrs)
          {
            object_id:    attrs["OBJECTID"].to_i,
            object_guid:  attrs["OBJECTGUID"],
            level_id:     attrs["LEVELID"].to_i,
            is_active:    attrs["ISACTIVE"] == "1",
            created_date: parse_date(attrs["CREATEDATE"]),
            updated_date: parse_date(attrs["UPDATEDATE"])
          }
        end

        private

        def should_yield_record?
          # Фильтр по level_id
          if (level_ids = @options[:level]) && !level_ids.include?(@current_record[:level_id])
            return false
          end

          # Фильтр по is_active
          return false if !@options[:is_active].nil? && @current_record[:is_active] != @options[:is_active]

          true
        end
      end
    end
  end
end
