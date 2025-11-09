# frozen_string_literal: true

require_relative "../base_parser"

module Gar
  module Entities
    module AddressObjects
      class Parser < BaseParser
        def xml_element_name
          "OBJECT"
        end

        def headers
          [:id, :object_id, :object_guid, :change_id, :name, :type_name, :level, :oper_type_id, :prev_id, :next_id,
           :update_date, :start_date, :end_date, :is_actual, :is_active]
        end

        def record_data_from_attributes(attrs)
          {
            id:           attrs["ID"].to_i,
            object_id:    attrs["OBJECTID"].to_i,
            object_guid:  attrs["OBJECTGUID"],
            change_id:    attrs["CHANGEID"].to_i,
            name:         attrs["NAME"],
            type_name:    attrs["TYPENAME"],
            level:        attrs["LEVEL"].to_i,
            oper_type_id: attrs["OPERTYPEID"].to_i,
            prev_id:      attrs["PREVID"].to_i,
            next_id:      attrs["NEXTID"].to_i,
            update_date:  parse_date(attrs["UPDATEDATE"]),
            start_date:   parse_date(attrs["STARTDATE"]),
            end_date:     parse_date(attrs["ENDDATE"]),
            is_actual:    attrs["ISACTUAL"] == "1",
            is_active:    attrs["ISACTIVE"] == "1"
          }
        end

        private

        def should_yield_record?
          # Фильтр по level
          if (levels = @options[:level]) && !levels.include?(@current_record[:level])
            return false
          end

          # Фильтр по is_actual
          return false if !@options[:is_actual].nil? && @current_record[:is_actual] != @options[:is_actual]

          # Фильтр по is_active
          return false if !@options[:is_active].nil? && @current_record[:is_active] != @options[:is_active]

          true
        end
      end
    end
  end
end
