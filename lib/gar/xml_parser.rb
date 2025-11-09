# frozen_string_literal: true

require "date"
require_relative "entities/entities"

module Gar
  class XmlParser
    include Loggable

    def parse_and_yield(xml_path:, table_name:, options: {})
      logger.debug "Начало парсинга XML: #{File.basename(xml_path)} для таблицы #{table_name}"

      records_buffer = []
      parser         = get_parser_class(table_name).new(options)
      batch_size     = Gar.configuration.batch_size

      parser.on_record do |record|
        # Буферизация записей
        records_buffer << record

        # Когда накопится батч, отдаем блоку для записи
        if records_buffer.size >= batch_size
          yield(records_buffer, parser.headers)
          records_buffer.clear
        end
      end

      parser.parse_file(xml_path)

      # Отдаем оставшиеся записи (если есть)
      yield(records_buffer, parser.headers) unless records_buffer.empty?

      logger.debug "Парсинг XML завершен: #{File.basename(xml_path)}"
    end

    private

    def get_parser_class(table_name)
      case table_name
      when :object_levels
        Xml::ObjectLevelsParser
      when :address_object_types
        Xml::AddressObjectTypesParser
      when :address_objects
        Xml::AddressObjectsParser
      when :house_types
        Xml::HouseTypesParser
      when :houses
        Xml::HousesParser
      when :reestr_objects
        Xml::ReestrObjectsParser
      when :adm_hierarchy
        Xml::AdmHierarchyParser
      when :mun_hierarchy
        Xml::MunHierarchyParser
      when :param_types
        Xml::ParamTypesParser
      when :params
        Xml::ParamsParser
      else
        Xml::NullParser
      end
    end
  end
end
