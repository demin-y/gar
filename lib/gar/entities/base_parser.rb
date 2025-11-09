# frozen_string_literal: true

require "date"
require "ox"

module Gar
  module Entities
    class BaseParser < Ox::Sax
      attr_reader :headers

      def initialize(options = {})
        super()
        @options            = options
        @element            = {}
        @on_record_callback = nil
      end

      def on_record(&block)
        @on_record_callback = block
      end

      def parse_file(xml_path)
        File.open(xml_path, "r") do |f|
          Ox.sax_parse(self, f)
        end
      end

      def parse_date(date_str)
        Date.parse(date_str) if date_str && !date_str.empty?
      rescue ArgumentError
        nil
      end

      def start_element(name)
        return unless name == xml_element_name.to_sym

        @element = {}
      end

      def attr(name, value)
        return unless @element

        @element[name.to_s] ||= value
      end

      def end_element(name)
        return unless name == xml_element_name.to_sym

        @current_record = record_data_from_attributes(@element)
        yield_record if should_yield_record?
        @element = nil
      end

      private

      def yield_record
        @on_record_callback&.call(@current_record)
      end

      def should_yield_record?
        true # Override in subclasses for filtering
      end
    end
  end
end
