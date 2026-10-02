# frozen_string_literal: true

require "pg"

module Gar
  # Декларативное описание всех таблиц архива ГАР: 10 справочников корня и 18 таблиц субъекта.
  # Из него строятся DDL, первичные ключи, индексы, команды COPY и разбор XML.
  #
  # Атрибут XML выводится из имени колонки: object_id → OBJECTID. Колонку region_code импорт
  # заполняет кодом субъекта из имени папки архива, производные колонки (пути) — построитель
  # путей; в XML их нет. Состав атрибутов сверяет спека с XSD из docs/xml_schema.
  module Schema
    SQL_TYPES = {
      bigint: "bigint", integer: "integer", text: "text", date: "date", boolean: "boolean", uuid: "uuid",
      tsvector: "tsvector"
    }.freeze

    Column =
      Data.define(:name, :type, :attribute) do
        def definition = "#{PG::Connection.quote_ident(name.to_s)} #{SQL_TYPES.fetch(type)}"
      end

    Index = Data.define(:name, :definition)

    REGION_CODE = Column.new(name: :region_code, type: :text, attribute: nil)

    # file    — ключ в имени файла архива: AS_<file>_<дата>_<guid>.XML;
    # element — элемент XML с одной записью;
    # actual  — условие актуальной записи (атрибут → значение); без keep_history остальные
    #           записи при разборе отбрасываются;
    # ignored — атрибуты XML, которые не храним (с пояснением в описании таблицы)
    Table =
      Data.define(:name, :file, :element, :regional, :region_code, :columns, :derived,
                  :primary_key, :indexes, :actual, :ignored) do
        def qualified_name(schema) = "#{quote(schema)}.#{quote(name)}"

        # Колонки, которые заполняет COPY, — в порядке значений строки XmlReader
        def copy_columns = region_code ? [*columns, REGION_CODE] : columns

        def params? = element == "PARAM"

        def create_sql(schema)
          definitions = [*copy_columns, *derived].map(&:definition)
          "CREATE TABLE #{qualified_name(schema)} (#{definitions.join(', ')})"
        end

        def copy_sql(schema)
          "COPY #{qualified_name(schema)} (#{copy_columns.map { quote(_1.name) }.join(', ')}) FROM STDIN"
        end

        def primary_key_sql(schema)
          return if primary_key.empty?

          "ALTER TABLE #{qualified_name(schema)} ADD PRIMARY KEY (#{primary_key.map { quote(_1) }.join(', ')})"
        end

        def index_sqls(schema)
          indexes.map do |index|
            "CREATE INDEX #{quote("idx_#{name}_#{index.name}")} ON #{qualified_name(schema)} #{index.definition}"
          end
        end

        private

        def quote(identifier) = PG::Connection.quote_ident(identifier.to_s)
      end

    # Набор колонок таблицы в блоке Schema.table
    class Builder
      attr_reader :columns, :derived, :primary_key, :indexes

      def initialize
        @columns     = []
        @derived     = []
        @primary_key = [:id]
        @indexes     = []
      end

      SQL_TYPES.each_key do |type|
        define_method(type) do |*names|
          names.each { |name| @columns << Column.new(name:, type:, attribute: name.to_s.delete("_").upcase) }
        end
      end

      # Колонки, которых нет в XML: их заполняет построитель путей
      def derived_columns(type, *names)
        names.each { |name| @derived << Column.new(name:, type:, attribute: nil) }
      end

      def key(*names)
        @primary_key = names
      end

      # По умолчанию — B-tree по одноимённой колонке
      def index(name, definition = "(#{PG::Connection.quote_ident(name.to_s)})")
        @indexes << Index.new(name:, definition:)
      end

      # Даты и признак активности справочника (ISACTIVE — true/false)
      def dictionary_validity
        date :update_date, :start_date, :end_date
        boolean :is_active
      end

      # Начало записи объекта: идентификаторы записи, объекта и изменения
      def object_identity
        bigint :id, :object_id
        uuid :object_guid
        bigint :change_id
      end

      # Конец записи объекта: связи версий, даты, признаки актуальности и активности (1/0)
      def object_history
        bigint :prev_id, :next_id
        date :update_date, :start_date, :end_date
        boolean :is_actual, :is_active
      end

      def object_indexes
        index :object_id
        index :object_guid
      end

      def paths
        derived_columns :text, :full_adm_path, :full_mun_path
        derived_columns :tsvector, :full_adm_path_tsv, :full_mun_path_tsv
      end

      # Строка иерархии без кодов: у административной они свои, у муниципальной — ОКТМО
      def hierarchy_item
        bigint :id, :object_id, :parent_obj_id, :change_id
        yield
        bigint :prev_id, :next_id
        date :update_date, :start_date, :end_date
        boolean :is_active
        text :path
        index :object_id
        index :parent_obj_id
      end

      # Параметр объекта (файлы AS_*_PARAMS, одна схема AS_PARAM)
      def param
        bigint :id, :object_id, :change_id, :change_id_end
        integer :type_id
        text :value
        date :update_date, :start_date, :end_date
        index :object_id
      end
    end

    ACTUAL_RECORD = { "ISACTUAL" => "1" }.freeze
    ACTIVE_ITEM   = { "ISACTIVE" => "1" }.freeze
    CURRENT_PARAM = { "CHANGEIDEND" => "0" }.freeze

    TABLE_DEFAULTS = { regional: true, region_code: false, actual: nil, ignored: [].freeze }.freeze

    # Именованные параметры — regional:, region_code:, actual:, ignored: (см. Table)
    def self.table(name, file, element, **, &)
      builder = Builder.new
      builder.instance_eval(&)
      Table.new(name:, file:, element:, **TABLE_DEFAULTS, **,
                columns: builder.columns.freeze, derived: builder.derived.freeze,
                primary_key: builder.primary_key.freeze, indexes: builder.indexes.freeze)
    end

    # Справочники корня архива
    DICTIONARIES = [
      table(:object_levels, "OBJECT_LEVELS", "OBJECTLEVEL", regional: false) do
        integer :level
        text :name, :short_name
        dictionary_validity
        key :level
      end,
      table(:address_object_types, "ADDR_OBJ_TYPES", "ADDRESSOBJECTTYPE", regional: false) do
        integer :id, :level
        text :short_name, :name, :desc
        dictionary_validity
      end,
      table(:house_types, "HOUSE_TYPES", "HOUSETYPE", regional: false) do
        integer :id
        text :name, :short_name, :desc
        dictionary_validity
      end,
      table(:add_house_types, "ADDHOUSE_TYPES", "HOUSETYPE", regional: false) do
        integer :id
        text :name, :short_name, :desc
        dictionary_validity
      end,
      table(:apartment_types, "APARTMENT_TYPES", "APARTMENTTYPE", regional: false) do
        integer :id
        text :name, :short_name, :desc
        dictionary_validity
      end,
      table(:room_types, "ROOM_TYPES", "ROOMTYPE", regional: false) do
        integer :id
        text :name, :short_name, :desc
        dictionary_validity
      end,
      table(:operation_types, "OPERATION_TYPES", "OPERATIONTYPE", regional: false) do
        integer :id
        text :name, :short_name, :desc
        dictionary_validity
      end,
      table(:param_types, "PARAM_TYPES", "PARAMTYPE", regional: false) do
        integer :id
        text :name, :code, :desc
        dictionary_validity
      end,
      table(:normative_docs_kinds, "NORMATIVE_DOCS_KINDS", "NDOCKIND", regional: false) do
        integer :id
        text :name
      end,
      table(:normative_docs_types, "NORMATIVE_DOCS_TYPES", "NDOCTYPE", regional: false) do
        integer :id
        text :name
        date :start_date, :end_date
      end
    ].freeze

    # Таблицы субъекта: по одному файлу в каждой папке NN/
    REGIONAL = [
      table(:address_objects, "ADDR_OBJ", "OBJECT", region_code: true, actual: ACTUAL_RECORD) do
        object_identity
        text :name, :type_name
        integer :level, :oper_type_id
        object_history
        paths
        object_indexes
        index :level
        index :fulltext, "USING gin (to_tsvector('russian', name || ' ' || type_name)) WHERE is_active = true"
      end,
      table(:addr_obj_division, "ADDR_OBJ_DIVISION", "ITEM") do
        bigint :id, :parent_id, :child_id, :change_id
        index :parent_id
        index :child_id
      end,
      table(:addr_obj_params, "ADDR_OBJ_PARAMS", "PARAM", actual: CURRENT_PARAM) { param },
      # Код субъекта берётся из имени папки (region_code), REGIONCODE из XML не храним
      table(:adm_hierarchy, "ADM_HIERARCHY", "ITEM", region_code: true, actual: ACTIVE_ITEM, ignored: ["REGIONCODE"]) do
        hierarchy_item { text :area_code, :city_code, :place_code, :plan_code, :street_code }
      end,
      table(:mun_hierarchy, "MUN_HIERARCHY", "ITEM", region_code: true, actual: ACTIVE_ITEM) do
        hierarchy_item { text :oktmo }
      end,
      table(:houses, "HOUSES", "HOUSE", region_code: true, actual: ACTUAL_RECORD) do
        object_identity
        text :house_num, :add_num1, :add_num2
        integer :house_type, :add_type1, :add_type2, :oper_type_id
        object_history
        paths
        object_indexes
      end,
      table(:house_params, "HOUSES_PARAMS", "PARAM", actual: CURRENT_PARAM) { param },
      table(:steads, "STEADS", "STEAD", region_code: true, actual: ACTUAL_RECORD) do
        object_identity
        text :number
        integer :oper_type_id
        object_history
        object_indexes
      end,
      table(:stead_params, "STEADS_PARAMS", "PARAM", actual: CURRENT_PARAM) { param },
      table(:apartments, "APARTMENTS", "APARTMENT", region_code: true, actual: ACTUAL_RECORD) do
        object_identity
        text :number
        integer :apart_type, :oper_type_id
        object_history
        object_indexes
      end,
      table(:apartment_params, "APARTMENTS_PARAMS", "PARAM", actual: CURRENT_PARAM) { param },
      table(:rooms, "ROOMS", "ROOM", region_code: true, actual: ACTUAL_RECORD) do
        object_identity
        text :number
        integer :room_type, :oper_type_id
        object_history
        object_indexes
      end,
      table(:room_params, "ROOMS_PARAMS", "PARAM", actual: CURRENT_PARAM) { param },
      table(:carplaces, "CARPLACES", "CARPLACE", region_code: true, actual: ACTUAL_RECORD) do
        object_identity
        text :number
        integer :oper_type_id
        object_history
        object_indexes
      end,
      table(:carplace_params, "CARPLACES_PARAMS", "PARAM", actual: CURRENT_PARAM) { param },
      table(:reestr_objects, "REESTR_OBJECTS", "OBJECT") do
        bigint :object_id
        uuid :object_guid
        bigint :change_id
        integer :level_id
        boolean :is_active
        date :create_date, :update_date
        key :object_id
        index :object_guid
      end,
      # Журнал операций: у одной транзакции (CHANGEID) бывает несколько объектов, ключа нет
      table(:change_history, "CHANGE_HISTORY", "ITEM") do
        bigint :change_id, :object_id
        uuid :adr_object_id
        integer :oper_type_id
        bigint :ndoc_id
        date :change_date
        key
        index :object_id
      end,
      table(:normative_docs, "NORMATIVE_DOCS", "NORMDOC") do
        bigint :id
        text :name
        date :date
        text :number
        integer :type, :kind
        date :update_date
        text :org_name, :reg_num
        date :reg_date, :acc_date
        text :comment
      end
    ].freeze

    TABLES = (DICTIONARIES + REGIONAL).to_h { [_1.name, _1] }.freeze

    def self.fetch(name)
      TABLES.fetch(name.to_sym) { raise ConfigurationError, "Неизвестная таблица ГАР: #{name}" }
    end
  end
end
