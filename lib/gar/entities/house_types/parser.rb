# frozen_string_literal: true

require_relative "../base_parser"

module Gar
  module Entities
    module HouseTypes
      class Parser < BaseParser
        def xml_element_name
          "HOUSETYPE"
        end

        def headers
          [:id, :name, :short_name, :desc, :update_date, :start_date, :end_date, :is_active]
        end

        def record_data_from_attributes(attrs)
          {
            id:          attrs["ID"]&.to_i,
            name:        attrs["NAME"],
            short_name:  attrs["SHORTNAME"],
            desc:        attrs["DESC"],
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
