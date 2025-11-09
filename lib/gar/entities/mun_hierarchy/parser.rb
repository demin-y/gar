# frozen_string_literal: true

require_relative "../base_parser"

module Gar
  module Entities
    module MunHierarchy
      class Parser < BaseParser
        def xml_element_name
          "ITEM"
        end

        def headers
          [:id, :object_id, :parent_obj_id, :change_id, :region_code, :area_code, :city_code, :place_code, :plan_code,
           :street_code, :prev_id, :next_id, :update_date, :start_date, :end_date, :is_active, :path]
        end

        def record_data_from_attributes(attrs)
          {
            id:            attrs["ID"].to_i,
            object_id:     attrs["OBJECTID"].to_i,
            parent_obj_id: attrs["PARENTOBJID"].to_i,
            change_id:     attrs["CHANGEID"].to_i,
            region_code:   attrs["REGIONCODE"],
            area_code:     attrs["AREACODE"],
            city_code:     attrs["CITYCODE"],
            place_code:    attrs["PLACECODE"],
            plan_code:     attrs["PLANCODE"],
            street_code:   attrs["STREETCODE"],
            prev_id:       attrs["PREVID"].to_i,
            next_id:       attrs["NEXTID"].to_i,
            update_date:   parse_date(attrs["UPDATEDATE"]),
            start_date:    parse_date(attrs["STARTDATE"]),
            end_date:      parse_date(attrs["ENDDATE"]),
            is_active:     attrs["ISACTIVE"] == "1",
            path:          attrs["PATH"]
          }
        end

        private

        def should_yield_record?
          # Фильтр по is_active
          return false if !@options[:is_active].nil? && @current_record[:is_active] != @options[:is_active]

          true
        end
      end
    end
  end
end
