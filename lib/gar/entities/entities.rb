# frozen_string_literal: true

# Auto-load table modules from subdirectories
Dir.glob(File.join(__dir__, "*/table.rb")).each do |file|
  dirname = File.basename(File.dirname(file))
  require_relative "#{dirname}/table"
  require_relative "#{dirname}/parser"
end

# Load special parsers
require_relative "null_parser"
require_relative "base_parser"

module Gar
  module Entities
    TABLE_MODULES = {
      object_levels:        Entities::ObjectLevels,
      address_object_types: Entities::AddressObjectTypes,
      address_objects:      Entities::AddressObjects,
      house_types:          Entities::HouseTypes,
      houses:               Entities::Houses,
      reestr_objects:       Entities::ReestrObjects,
      adm_hierarchy:        Entities::AdmHierarchy,
      mun_hierarchy:        Entities::MunHierarchy,
      param_types:          Entities::ParamTypes,
      params:               Entities::Params
    }.freeze

    def self.get_table_module(table_name)
      TABLE_MODULES[table_name.to_sym]
    end

    def self.all_table_names
      TABLE_MODULES.keys
    end

    def self.importable_tables
      # Default tables to import - can be configured
      [
        :object_levels,
        :address_object_types, :address_objects,
        :house_types, :houses,
        :reestr_objects,
        :adm_hierarchy, :mun_hierarchy,
        :param_types, :params
      ]
    end
  end

  # Backward compatibility aliases for XmlParser
  module Xml
    ObjectLevelsParser        = Entities::ObjectLevels::Parser
    AddressObjectTypesParser  = Entities::AddressObjectTypes::Parser
    AddressObjectsParser      = Entities::AddressObjects::Parser
    HouseTypesParser          = Entities::HouseTypes::Parser
    HousesParser              = Entities::Houses::Parser
    ReestrObjectsParser       = Entities::ReestrObjects::Parser
    AdmHierarchyParser        = Entities::AdmHierarchy::Parser
    MunHierarchyParser        = Entities::MunHierarchy::Parser
    ParamTypesParser          = Entities::ParamTypes::Parser
    ParamsParser              = Entities::Params::Parser
    NullParser                = Entities::NullParser
  end
end
