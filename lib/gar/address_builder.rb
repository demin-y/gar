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
  # Улица — самый глубокий элемент уровня 7 или 8: улица, а без неё — элемент планировочной
  # структуры (СНТ, микрорайон); город — населённый пункт (уровни 5, 6 или тип «город»).
  # Индекс, ОКАТО и ОКТМО — параметры объекта; индекса нет у объекта — берётся у ближайшего
  # предка. Без таблиц параметров эти поля — nil.
  class AddressBuilder
    LEVELS = { district: [2, 3], city: [5, 6], street: [7, 8] }.freeze
    PARAMS = { postal_code: Schema::POSTAL_CODE_PARAM, okato: 6, oktmo: 7 }.freeze
    OFFICIAL_NAME = 16
    OFFICIAL_LEVELS = [1, 3, 4].freeze
    HOUSE_LEVEL = 10
    # GUID в одной пачке Gar.address(guids)
    BATCH = 1_000
    # Номера дома: префикс колонок типа в target → колонка номера
    HOUSE_NUMBERS = { "type" => "house_num", "add1" => "add_num1", "add2" => "add_num2" }.freeze
    # Полный тип, по которому объект любого уровня — город (Москва — субъект и город)
    CITY_TYPE = "город"

    attr_reader :search

    def initialize(search = Search.new) = @search = search

    def call(guid, hierarchy: nil)
      batch([guid], hierarchy:)[guid] if guid.to_s.match?(Search::UUID)
    end

    # Адреса пачки GUID (Т27): Hash GUID → Gar::Address или nil (как Gar.address по одному).
    # На каждые BATCH GUID — постоянное число запросов: объекты, пути, элементы путей, параметры
    def batch(guids, hierarchy: nil)
      hierarchy = search.resolve(hierarchy)
      valid     = guids.select { _1.to_s.match?(Search::UUID) }.uniq
      result    = guids.to_h { [_1, nil] }
      return result if valid.empty?

      search.with_connection do |conn|
        tables = Database.existing_relations(conn, [table(:addr_obj_params), table(:house_params)])
        valid.each_slice(BATCH) do |slice|
          found = addresses(conn, slice.map(&:to_s), hierarchy, tables)
          slice.each { result[_1] = found[_1.to_s.downcase] }
        end
      end
      result
    end

    # Состояние объекта по GUID (Gar::AddressStatus): актуальная запись адресного объекта или
    # дома, действующая — первой
    def status(guid)
      return AddressStatus.not_found(guid) unless guid.to_s.match?(Search::UUID)

      search.with_connection do |conn|
        row = conn.exec_params(<<~SQL, [guid]).first
          SELECT s.*, o.name AS operation FROM (
            SELECT object_id, level, is_active, update_date, end_date, oper_type_id
            FROM #{table(:address_objects)} WHERE object_guid = $1 AND is_actual
            UNION ALL
            SELECT object_id, #{HOUSE_LEVEL}, is_active, update_date, end_date, oper_type_id
            FROM #{table(:houses)} WHERE object_guid = $1 AND is_actual
          ) s LEFT JOIN #{table(:operation_types)} o ON o.id = s.oper_type_id
          ORDER BY s.is_active DESC LIMIT 1
        SQL
        row ? AddressStatus.from_row(guid, row) : AddressStatus.not_found(guid)
      end
    end

    private

    # Адреса GUID пачки: GUID (в нижнем регистре, как в базе) → Gar::Address
    # tables — загруженные таблицы параметров
    def addresses(conn, guids, hierarchy, tables)
      targets = targets(conn, guids)
      return {} if targets.empty?

      paths    = paths(conn, targets.map { _1["object_id"].to_i }, hierarchy)
      ids      = paths.values.flatten.uniq
      tables  -= [table(:house_params)] unless targets.any? { _1["house"] == "t" }
      elements = elements(conn, ids, tables.include?(table(:addr_obj_params)))
      values   = param_rows(conn, ids, tables)
      targets.filter_map do |target|
        path = paths[target["object_id"].to_i] or next
        [target["object_guid"], build(target, path.filter_map { elements[_1] }, params(values, path), hierarchy)]
      end.to_h
    end

    # Действующие объекты по GUID (актуальная запись, как в status): адресные объекты и дома с
    # номерами и их типами
    def targets(conn, guids)
      conn.exec_params(<<~SQL, [Database.array(guids)]).to_a.uniq { _1["object_guid"] }
        SELECT object_id, object_guid, level, region_code, false AS house, NULL AS house_num, NULL AS add_num1, NULL AS add_num2,
               NULL AS type_name, NULL AS type_short, NULL AS add1_name, NULL AS add1_short, NULL AS add2_name, NULL AS add2_short
        FROM #{table(:address_objects)} WHERE object_guid = ANY($1::uuid[]) AND is_actual AND is_active
        UNION ALL
        SELECT h.object_id, h.object_guid, #{HOUSE_LEVEL}, h.region_code, true, h.house_num, h.add_num1, h.add_num2,
               ht.name, ht.short_name, a1.name, a1.short_name, a2.name, a2.short_name
        FROM #{table(:houses)} h #{search.house_type_joins}
        WHERE h.object_guid = ANY($1::uuid[]) AND h.is_actual AND h.is_active
      SQL
    end

    # OBJECTID → OBJECTID пути от субъекта до объекта; объекта без строки в иерархии нет в ответе
    def paths(conn, object_ids, hierarchy)
      rows = conn.exec_params("SELECT object_id, path FROM #{search.hierarchy_table(hierarchy)} " \
                              "WHERE object_id = ANY($1::bigint[]) AND is_active", [Database.array(object_ids)])
      rows.to_h { [_1["object_id"].to_i, _1["path"].split(".").map(&:to_i)] }
    rescue PG::UndefinedTable
      search.require_hierarchy(conn, hierarchy)
      raise
    end

    def build(target, elements, params, hierarchy)
      house = house(target) if target["house"] == "t"
      chain = elements.reject { _1.gar_object_id == target["object_id"].to_i }
      Address.new(
        object_guid: target["object_guid"], gar_object_id: target["object_id"].to_i, level: target["level"].to_i, hierarchy:,
        region_code: target["region_code"], **parts(elements), **house_parts(house), **params,
        parent_guids: chain.map(&:object_guid), elements:,
        full_address: [*elements.map(&:full_name), house&.full_name].compact.join(", "),
        short_address: [*elements.map(&:short_name), house&.short_name].compact.join(", ")
      )
    end

    # Действующие адресные объекты по OBJECTID (OBJECTID → AddressElement): полный тип из
    # справочника и действующее официальное наименование (если таблица параметров загружена)
    def elements(conn, object_ids, official)
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
      conn.exec_params(<<~SQL, [Database.array(object_ids)]).to_h { [_1["object_id"].to_i, element(_1)] }
        SELECT ao.object_id, ao.object_guid, ao.level, ao.name, ao.type_name, t.name AS type_full_name,
               #{official ? 'official.value' : 'NULL'} AS official_name
        FROM #{table(:address_objects)} ao
        LEFT JOIN LATERAL (
          SELECT name FROM #{table(:address_object_types)} t
          WHERE t.short_name = ao.type_name AND t.level = ao.level ORDER BY t.end_date DESC, t.id DESC LIMIT 1
        ) t ON true
        #{official_join}
        WHERE ao.object_id = ANY($1::bigint[]) AND ao.is_actual AND ao.is_active
      SQL
    end

    def element(row)
      name      = row["official_name"]
      full_type = (row["type_full_name"] || row["type_name"]).downcase
      AddressElement.new(gar_object_id: row["object_id"].to_i, object_guid: row["object_guid"], level: row["level"].to_i,
                         name: row["name"], short_type: row["type_name"], full_type:,
                         short_name: name || "#{row['type_name']} #{row['name']}", full_name: name || "#{full_type} #{row['name']}")
    end

    # Дом (Gar::HouseElement): тип и номер; литера — часть номера в регистре ГАР («18» и литера
    # «Б» — «18Б»), остальные дополнительные номера — с типами
    def house(row)
      main, *added = HOUSE_NUMBERS.map { |prefix, column| house_number(row, prefix, column) }
      numbers = [main, *added].select(&:number)
      name    = ->(type) { numbers.map { [_1.public_send(type), _1.number].compact.join(" ") }.join(" ") }
      number  = [main.number, HouseNumber.letters(added.map { [_1.full_type, _1.number] })].compact.join
      HouseElement.new(number: (number unless number.empty?), short_type: main.short_type, full_type: main.full_type,
                       additions: added.select(&:number).reject { HouseNumber.letter_type?(_1.full_type) },
                       short_name: name.call(:short_type), full_name: name.call(:full_type))
    end

    # Номер дома или дополнительный номер с типом: prefix — колонки типа в target, column — номера
    def house_number(row, prefix, column)
      HouseAddition.new(short_type: row["#{prefix}_short"], full_type: row["#{prefix}_name"]&.downcase, number: row[column])
    end

    # Поля дома в Gar::Address: номер, корпус и строение — по правилу HouseNumber.additional_parts (только
    # дополнительные номера: у «стр. 9» structure нет) — и сам дом
    def house_parts(house)
      parts = HouseNumber.additional_parts(house ? house.additions.map { [_1.full_type, _1.number] } : [])
      { house: house&.number, **HouseNumber::TYPES.keys.to_h { [_1, parts[_1]] }, house_element: house }
    end

    # Действующие параметры PARAMS объектов object_ids из загруженных таблиц tables: OBJECTID →
    # строки, новые первыми
    def param_rows(conn, object_ids, tables)
      return {} if tables.empty?

      conn.exec_params(<<~SQL, [Database.array(object_ids), Database.array(PARAMS.values)]).to_a.group_by { _1["object_id"].to_i }
        SELECT object_id, type_id, value FROM (#{tables.map { "SELECT id, object_id, type_id, value, end_date FROM #{_1}" }.join(' UNION ALL ')}) p
        WHERE object_id = ANY($1::bigint[]) AND type_id = ANY($2::int[]) AND (end_date IS NULL OR end_date > current_date)
        ORDER BY id DESC
      SQL
    end

    # Индекс, ОКАТО и ОКТМО: значение объекта, иначе ближайшего предка по пути (rows — param_rows)
    def params(rows, path)
      values = path.reverse_each.flat_map { rows.fetch(_1, []) }
      PARAMS.transform_values { |type_id| values.find { _1["type_id"].to_i == type_id }&.fetch("value") }
    end

    # Части адреса: самый глубокий элемент уровня. Город — уровни 5 и 6 или тип «город» на
    # любом уровне (город — субъект или городской округ). У города и улицы — ещё и GUID
    def parts(elements)
      is_city  = -> { LEVELS[:city].include?(_1.level) || _1.full_type == CITY_TYPE }
      deepest  = ->(&block) { elements.reverse_each.find(&block) }
      city     = deepest.call(&is_city)
      street   = deepest.call { LEVELS[:street].include?(_1.level) }
      district = deepest.call { LEVELS[:district].include?(_1.level) && !is_city.call(_1) }
      { region: elements.find { _1.level == 1 }&.full_name, city: city&.full_name, city_guid: city&.object_guid,
        district: district&.full_name, street: street&.full_name, street_guid: street&.object_guid }
    end

    def table(name) = search.table(name)
  end
end
