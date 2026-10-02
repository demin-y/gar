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
    SQL_TYPES = [:bigint, :integer, :text, :date, :boolean, :uuid, :tsvector].freeze

    def self.quote(identifier) = PG::Connection.quote_ident(identifier.to_s)

    # type — тип SQL; у производной колонки может быть с условием (GENERATED ALWAYS AS …)
    Column =
      Data.define(:name, :type) do
        def attribute = name.to_s.delete("_").upcase
        def definition = "#{Schema.quote(name)} #{type}"
      end

    Index = Data.define(:name, :definition)

    REGION_CODE = Column.new(name: :region_code, type: :text)

    # file    — ключ в имени файла архива: AS_<file>_<дата>_<guid>.XML;
    # element — элемент XML с одной записью;
    # columns — колонки из атрибутов XML; derived — производные: пути (заполняет построитель
    #           путей) и вычисляемые колонки;
    # actual  — условие актуальной записи (атрибут → значение); без keep_history остальные
    #           записи при разборе отбрасываются;
    # ignored — атрибуты XML, которые не храним (с пояснением в описании таблицы)
    Table =
      Data.define(:name, :file, :element, :regional, :region_code, :columns, :derived,
                  :primary_key, :indexes, :actual, :ignored) do
        def qualified_name(schema) = "#{Schema.quote(schema)}.#{Schema.quote(name)}"

        # Колонки, которые заполняет COPY, — в порядке значений строки XmlReader
        def copy_columns = region_code ? [*columns, REGION_CODE] : columns

        def params? = element == "PARAM"

        # Таблица с путями по иерархиям (их строит PathBuilder)
        def paths? = derived.any? { _1.name == :full_adm_path }

        def create_sql(schema)
          "CREATE TABLE #{qualified_name(schema)} (#{[*copy_columns, *derived].map(&:definition).join(', ')})"
        end

        def copy_sql(schema)
          "COPY #{qualified_name(schema)} (#{copy_columns.map { Schema.quote(_1.name) }.join(', ')}) FROM STDIN"
        end

        # Первичный ключ и индексы: строятся после загрузки, чтобы COPY их не поддерживал
        def index_sqls(schema)
          key = "ALTER TABLE #{qualified_name(schema)} ADD PRIMARY KEY (#{primary_key.map { Schema.quote(_1) }.join(', ')})"
          indexes =
            self.indexes.map do |index|
              "CREATE INDEX #{Schema.quote("idx_#{name}_#{index.name}")} ON #{qualified_name(schema)} #{index.definition}"
            end
          primary_key.empty? ? indexes : [key, *indexes]
        end
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

      SQL_TYPES.each do |type|
        define_method(type) { |*names| @columns.concat(names.map { Column.new(name: _1, type:) }) }
      end

      def key(*names)
        @primary_key = names
      end

      # По умолчанию — B-tree по одноимённой колонке
      def index(name, definition = "(#{Schema.quote(name)})")
        @indexes << Index.new(name:, definition:)
      end

      # Даты и признак активности справочника (ISACTIVE — true/false)
      def dictionary_validity
        date :update_date, :start_date, :end_date
        boolean :is_active
      end

      # Справочник типов: полное и краткое наименование, описание
      def type_dictionary
        integer :id
        text :name, :short_name, :desc
        dictionary_validity
      end

      # Запись объекта (адресный объект, дом, участок, помещение): свои колонки — в блоке,
      # между общими идентификаторами и признаками актуальности (ISACTUAL/ISACTIVE — 1/0)
      def object_record(&)
        bigint :id, :object_id
        uuid :object_guid
        bigint :change_id
        instance_eval(&)
        bigint :prev_id, :next_id
        date :update_date, :start_date, :end_date
        boolean :is_actual, :is_active
        index :object_id
        index :object_guid
      end

      # Полные пути, их tsvector и OBJECTID объектов пути от корня до самого объекта (для
      # поиска в границах и пересборки поддерева): заполняет построитель путей
      def paths
        @derived.concat([:full_adm_path, :full_mun_path].map { Column.new(name: _1, type: :text) })
        @derived.concat([:full_adm_path_tsv, :full_mun_path_tsv].map { Column.new(name: _1, type: :tsvector) })
        @derived.concat([:adm_path_ids, :mun_path_ids].map { Column.new(name: _1, type: :"bigint[]") })
      end

      # Вычисляемая колонка: PostgreSQL считает её сам при COPY и UPDATE
      def generated(name, type, expression)
        @derived << Column.new(name:, type: "#{type} GENERATED ALWAYS AS (#{expression}) STORED")
      end

      # Строка иерархии; в блоке — коды: у административной свои, у муниципальной — ОКТМО
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

    class << self
      # Именованные параметры — regional:, region_code:, actual:, ignored: (см. Table)
      def table(name, file, element, **, &)
        builder = Builder.new
        builder.instance_eval(&)
        Table.new(name:, file:, element:, **TABLE_DEFAULTS, **,
                  columns: builder.columns.freeze, derived: builder.derived.freeze,
                  primary_key: builder.primary_key.freeze, indexes: builder.indexes.freeze)
      end

      def dictionary(name, file, element, &) = table(name, file, element, regional: false, &)

      def object_table(name, file, element, &columns)
        table(name, file, element, region_code: true, actual: ACTUAL_RECORD) { object_record(&columns) }
      end

      def params_table(name, file) = table(name, file, "PARAM", actual: CURRENT_PARAM) { param }
    end

    # Справочники корня архива
    DICTIONARIES = [
      dictionary(:object_levels, "OBJECT_LEVELS", "OBJECTLEVEL") do
        integer :level
        text :name, :short_name
        dictionary_validity
        key :level
      end,
      dictionary(:address_object_types, "ADDR_OBJ_TYPES", "ADDRESSOBJECTTYPE") do
        integer :id, :level
        text :short_name, :name, :desc
        dictionary_validity
      end,
      dictionary(:house_types, "HOUSE_TYPES", "HOUSETYPE") { type_dictionary },
      dictionary(:add_house_types, "ADDHOUSE_TYPES", "HOUSETYPE") { type_dictionary },
      dictionary(:apartment_types, "APARTMENT_TYPES", "APARTMENTTYPE") { type_dictionary },
      dictionary(:room_types, "ROOM_TYPES", "ROOMTYPE") { type_dictionary },
      dictionary(:operation_types, "OPERATION_TYPES", "OPERATIONTYPE") { type_dictionary },
      dictionary(:param_types, "PARAM_TYPES", "PARAMTYPE") do
        integer :id
        text :name, :code, :desc
        dictionary_validity
      end,
      dictionary(:normative_docs_kinds, "NORMATIVE_DOCS_KINDS", "NDOCKIND") do
        integer :id
        text :name
      end,
      dictionary(:normative_docs_types, "NORMATIVE_DOCS_TYPES", "NDOCTYPE") do
        integer :id
        text :name
        date :start_date, :end_date
      end
    ].freeze

    # Таблицы субъекта: по одному файлу в каждой папке NN/
    REGIONAL = [
      object_table(:address_objects, "ADDR_OBJ", "OBJECT") do
        text :name, :type_name
        integer :level, :oper_type_id
        paths
        index :level
        index :fulltext, "USING gin (to_tsvector('russian', name || ' ' || type_name)) WHERE is_active = true"
      end,
      table(:addr_obj_division, "ADDR_OBJ_DIVISION", "ITEM") do
        bigint :id, :parent_id, :child_id, :change_id
        index :parent_id
        index :child_id
      end,
      params_table(:addr_obj_params, "ADDR_OBJ_PARAMS"),
      # Код субъекта берётся из имени папки (region_code), REGIONCODE из XML не храним
      table(:adm_hierarchy, "ADM_HIERARCHY", "ITEM", region_code: true, actual: ACTIVE_ITEM, ignored: ["REGIONCODE"]) do
        hierarchy_item { text :area_code, :city_code, :place_code, :plan_code, :street_code }
      end,
      table(:mun_hierarchy, "MUN_HIERARCHY", "ITEM", region_code: true, actual: ACTIVE_ITEM) do
        hierarchy_item { text :oktmo }
      end,
      object_table(:houses, "HOUSES", "HOUSE") do
        text :house_num, :add_num1, :add_num2
        integer :house_type, :add_type1, :add_type2, :oper_type_id
        paths
        # Номер для сравнения: без пробелов, в нижнем регистре, ё → е («10 А» → «10а»)
        generated :house_num_norm, :text, "translate(lower(regexp_replace(house_num, '\\s+', '', 'g')), 'ё', 'е')"
      end,
      params_table(:house_params, "HOUSES_PARAMS"),
      object_table(:steads, "STEADS", "STEAD") do
        text :number
        integer :oper_type_id
      end,
      params_table(:stead_params, "STEADS_PARAMS"),
      object_table(:apartments, "APARTMENTS", "APARTMENT") do
        text :number
        integer :apart_type, :oper_type_id
      end,
      params_table(:apartment_params, "APARTMENTS_PARAMS"),
      object_table(:rooms, "ROOMS", "ROOM") do
        text :number
        integer :room_type, :oper_type_id
      end,
      params_table(:room_params, "ROOMS_PARAMS"),
      object_table(:carplaces, "CARPLACES", "CARPLACE") do
        text :number
        integer :oper_type_id
      end,
      params_table(:carplace_params, "CARPLACES_PARAMS"),
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
    # Таблицы объектов (адресные объекты, дома, участки, помещения, машино-места): у них есть
    # строки в иерархиях
    OBJECT_TABLES = REGIONAL.select { _1.actual == ACTUAL_RECORD }.map(&:name).freeze

    def self.fetch(name)
      TABLES.fetch(name.to_sym) { raise ConfigurationError, "Неизвестная таблица ГАР: #{name}" }
    end
  end
end
