# frozen_string_literal: true

require_relative "../base_parser"

module Gar
  module Entities
    module Params
      class Parser < BaseParser
        def xml_element_name
          "PARAM"
        end

        def headers
          [:id, :object_id, :change_id, :change_id_end, :type_id, :value, :update_date, :start_date, :end_date]
        end

        def record_data_from_attributes(attrs)
          {
            id:            attrs["ID"].to_i,
            object_id:     attrs["OBJECTID"].to_i,
            change_id:     attrs["CHANGEID"].to_i,
            change_id_end: attrs["CHANGEIDEND"].to_i,
            type_id:       attrs["TYPEID"].to_i,
            value:         attrs["VALUE"],
            update_date:   parse_date(attrs["UPDATEDATE"]),
            start_date:    parse_date(attrs["STARTDATE"]),
            end_date:      parse_date(attrs["ENDDATE"])
          }
        end
      end
    end
  end
end
