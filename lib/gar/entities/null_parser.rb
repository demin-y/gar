# frozen_string_literal: true

require_relative "base_parser"

module Gar
  module Entities
    class NullParser < BaseParser
      def xml_element_name
        "NULL"
      end

      def headers
        []
      end

      def record_data_from_attributes(_attrs)
        {}
      end

      def should_yield_record?
        false
      end
    end
  end
end
