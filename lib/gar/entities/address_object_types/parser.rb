# frozen_string_literal: true

require_relative "../base_parser"

module Gar
  module Entities
    module AddressObjectTypes
      class Parser < BaseParser
        def xml_element_name
          "ADDRESSOBJECTTYPE"
        end

        def headers
          [:id, :level, :short_name, :name, :desc, :update_date, :start_date, :end_date, :is_active]
        end

        def record_data_from_attributes(attrs)
          {
            id:          attrs["ID"].to_i,
            level:       attrs["LEVEL"].to_i,
            short_name:  attrs["SHORTNAME"],
            name:        attrs["NAME"],
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
