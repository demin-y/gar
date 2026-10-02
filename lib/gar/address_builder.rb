# frozen_string_literal: true

module Gar
  # Разобранный адрес по GUID (Т8, Gar.address): элементы пути по иерархии и строка адреса по
  # правилам ФНС (docs/Правила_формирования_адресной_строки.docx):
  # - путь — PATH действующей строки иерархии объекта;
  # - полное наименование элемента — тип → наименование, тип полный («улица Ленина»): из
  #   справочника типов по краткому имени и уровню, последняя запись;
  # - у субъекта, муниципального района и поселения (уровни 1, 3, 4) — действующее официальное
  #   наименование (параметр 16), если оно есть;
  # - дом — тип и номер, затем дополнительные типы и номера («дом 14 корпус 1 строение 3»);
  # - элементы — через «, ».
  # Индекс, ОКАТО и ОКТМО — параметры объекта; индекса нет у объекта — берётся у ближайшего
  # предка. Без таблиц параметров эти поля — nil.
  class AddressBuilder
    LEVELS = { district: [2, 3], city: [5, 6], street: [7, 8] }.freeze
    PARAMS = { postal_code: Search::POSTAL_CODE_PARAM, okato: 6, oktmo: 7 }.freeze
    OFFICIAL_NAME = 16
    OFFICIAL_LEVELS = [1, 3, 4].freeze
    HOUSE_LEVEL = 10
    # Номера дома: префикс колонок типа в target → колонка номера
    HOUSE_NUMBERS = { "type" => "house_num", "add1" => "add_num1", "add2" => "add_num2" }.freeze
    # Полный тип, по которому объект любого уровня — город (Москва — субъект и город)
    CITY_TYPE = "город"

    # full_type — полный тип в нижнем регистре («улица»)
    Element = Data.define(:gar_object_id, :object_guid, :level, :full_type, :short_name, :full_name)

    attr_reader :search

    def initialize(search = Search.new) = @search = search

    def call(guid, hierarchy: nil)
      return unless guid.to_s.match?(Search::UUID)

      hierarchy = search.resolve(hierarchy)
      Database.with_connection(search.db_conn) do |conn|
        target = target(conn, guid) or next
        path   = path(conn, target, hierarchy) or next
        build(conn, target, path, hierarchy)
      end
    end

    private

    # Объект по GUID: адресный объект или дом с номерами и их типами
    def target(conn, guid)
      conn.exec_params(<<~SQL, [guid]).first
        SELECT object_id, object_guid, level, region_code, false AS house, NULL AS house_num, NULL AS add_num1, NULL AS add_num2,
               NULL AS type_name, NULL AS type_short, NULL AS add1_name, NULL AS add1_short, NULL AS add2_name, NULL AS add2_short
        FROM #{table(:address_objects)} WHERE object_guid = $1 AND is_active
        UNION ALL
        SELECT h.object_id, h.object_guid, #{HOUSE_LEVEL}, h.region_code, true, h.house_num, h.add_num1, h.add_num2,
               ht.name, ht.short_name, a1.name, a1.short_name, a2.name, a2.short_name
        FROM #{table(:houses)} h
        LEFT JOIN #{table(:house_types)} ht ON ht.id = h.house_type
        LEFT JOIN #{table(:add_house_types)} a1 ON a1.id = h.add_type1
        LEFT JOIN #{table(:add_house_types)} a2 ON a2.id = h.add_type2
        WHERE h.object_guid = $1 AND h.is_active
        LIMIT 1
      SQL
    end

    # OBJECTID пути от субъекта до объекта; nil — у объекта нет строки в иерархии
    def path(conn, target, hierarchy)
      rows = conn.exec_params("SELECT path FROM #{search.hierarchy_table(hierarchy)} WHERE object_id = $1 AND is_active LIMIT 1",
                              [target["object_id"]])
      rows.first && rows.getvalue(0, 0).split(".").map(&:to_i)
    rescue PG::UndefinedTable
      search.require_hierarchy(conn, hierarchy)
      raise
    end

    def build(conn, target, path, hierarchy)
      params   = Database.existing_relations(conn, [table(:addr_obj_params), table(:house_params)])
      elements = elements(conn, path, params.include?(table(:addr_obj_params)))
      house    = house(target) if target["house"] == "t"
      params  -= [table(:house_params)] unless house
      chain    = elements.reject { _1.gar_object_id == target["object_id"].to_i }
      Address.new(
        object_guid: target["object_guid"], gar_object_id: target["object_id"].to_i, level: target["level"].to_i, hierarchy:,
        region_code: target["region_code"], **parts(elements), house: house&.fetch(:number), building: house&.fetch(:building),
        structure: house&.fetch(:structure), **params(conn, path, params), parent_guids: chain.map(&:object_guid),
        full_address: [*elements.map(&:full_name), house&.fetch(:full_name)].compact.join(", "),
        short_address: [*elements.map(&:short_name), house&.fetch(:short_name)].compact.join(", ")
      )
    end

    # Адресные объекты пути по порядку: полный тип из справочника и действующее официальное
    # наименование (если таблица параметров загружена)
    def elements(conn, path, official)
      official_join =
        if official
          <<~SQL
            LEFT JOIN LATERAL (
              SELECT value FROM #{table(:addr_obj_params)} p
              WHERE p.object_id = ao.object_id AND p.type_id = #{OFFICIAL_NAME} AND ao.level IN (#{OFFICIAL_LEVELS.join(', ')})
                AND (p.end_date IS NULL OR p.end_date > current_date)
              ORDER BY p.id DESC LIMIT 1
            ) official ON true
          SQL
        end
      conn.exec_params(<<~SQL, [Database.array(path)]).map { element(_1) }
        SELECT ao.object_id, ao.object_guid, ao.level, ao.name, ao.type_name, t.name AS type_full_name,
               #{official ? 'official.value' : 'NULL'} AS official_name
        FROM unnest($1::bigint[]) WITH ORDINALITY AS item(object_id, ord)
        JOIN #{table(:address_objects)} ao ON ao.object_id = item.object_id AND ao.is_actual AND ao.is_active
        LEFT JOIN LATERAL (
          SELECT name FROM #{table(:address_object_types)} t
          WHERE t.short_name = ao.type_name AND t.level = ao.level ORDER BY t.end_date DESC, t.id DESC LIMIT 1
        ) t ON true
        #{official_join}
        ORDER BY item.ord
      SQL
    end

    def element(row)
      name      = row["official_name"]
      full_type = (row["type_full_name"] || row["type_name"]).downcase
      Element.new(gar_object_id: row["object_id"].to_i, object_guid: row["object_guid"], level: row["level"].to_i, full_type:,
                  short_name: name || "#{row['type_name']} #{row['name']}", full_name: name || "#{full_type} #{row['name']}")
    end

    # Номер дома: основной номер, корпус и строение, наименование полное и краткое
    def house(row)
      numbers = HOUSE_NUMBERS.select { row[_2] }
      parts   = HouseNumber::TYPES.transform_values { |type| numbers.find { |prefix, _| row["#{prefix}_name"]&.downcase == type }&.then { row[_2] } }
      full    = numbers.map { |prefix, column| [row["#{prefix}_name"]&.downcase, row[column]].compact.join(" ") }
      short   = numbers.map { |prefix, column| [row["#{prefix}_short"], row[column]].compact.join(" ") }
      { number: row["house_num"], **parts, full_name: full.join(" "), short_name: short.join(" ") }
    end

    # Индекс, ОКАТО и ОКТМО: значение объекта, иначе ближайшего предка по пути. tables —
    # загруженные таблицы параметров
    def params(conn, path, tables)
      return PARAMS.transform_values { nil } if tables.empty?

      rows = conn.exec_params(<<~SQL, [Database.array(path), Database.array(PARAMS.values)]).to_a
        SELECT object_id, type_id, value FROM (#{tables.map { "SELECT id, object_id, type_id, value, end_date FROM #{_1}" }.join(' UNION ALL ')}) p
        WHERE object_id = ANY($1::bigint[]) AND type_id = ANY($2::int[]) AND (end_date IS NULL OR end_date > current_date)
        ORDER BY id DESC
      SQL
      depth = path.each_with_index.to_h
      PARAMS.transform_values do |type_id|
        rows.select { _1["type_id"].to_i == type_id }.max_by { depth.fetch(_1["object_id"].to_i, -1) }&.fetch("value")
      end
    end

    # Части адреса: самый глубокий элемент уровня. Город — уровни 5 и 6 или тип «город» на
    # любом уровне (город — субъект или городской округ)
    def parts(elements)
      cities = elements.select { LEVELS[:city].include?(_1.level) || _1.full_type == CITY_TYPE }
      { region: elements.find { _1.level == 1 }&.full_name, city: cities.last&.full_name,
        district: elements.select { LEVELS[:district].include?(_1.level) && !cities.include?(_1) }.last&.full_name,
        street: elements.select { LEVELS[:street].include?(_1.level) }.last&.full_name }
    end

    def table(name) = search.table(name)
  end
end
