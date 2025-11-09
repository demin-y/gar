# frozen_string_literal: true

require_relative "../base_parser"

module Gar
  module Entities
    module ObjectLevels
      class Parser < BaseParser
        def xml_element_name
          "OBJECTLEVEL"
        end

        def headers
          [:level, :name, :update_date, :start_date, :end_date, :is_active]
        end

        def record_data_from_attributes(attrs)
          {
            level:       attrs["LEVEL"].to_i,
            name:        attrs["NAME"],
            update_date: parse_date(attrs["UPDATEDATE"]),
            start_date:  parse_date(attrs["STARTDATE"]),
            end_date:    parse_date(attrs["ENDDATE"]),
            is_active:   attrs["ISACTIVE"] == "true"
          }
        end
      end
    end
  end
end
