# frozen_string_literal: true

module Gar
  module TestSupport
    # Связный синтетический набор ГАР в формате архива: записи — атрибуты XML, как в файлах ФНС.
    # Из него Gar::TestSupport.load_fixtures заполняет тестовую схему, а спеки гема собирают
    # синтетический zip.
    #
    # - 43 Кировская обл. → (г.о. город Киров) → г. Киров → ул. Ленина (дома 10, 10а, 10/2,
    #   12 к. 2, 12 стр. 1, 14 к. 1 стр. 3, снесённый 16, 18 литера Б), ул. Воровского (бывш.
    #   Старая, дом 5), Октябрьский пр-кт и ул. Большая Садовая (для синонимов), упразднённая
    #   ул. Заводская; Киров — административный центр, рядом п. Кировский (для ранжирования);
    # - 11 Республика Коми → Сыктывкар → ул. Ленина, дом 10 (та же улица в другом субъекте);
    # - 77 Москва → ул. Тверская, дом 1;
    # - 50 цепочка из правил ФНС (docs/Правила_формирования_адресной_строки.docx): Московская
    #   обл. → г.о. Павлово-Посадский → г. Павловский Посад → ул. Тихонова → дом 93 → кв. 17 →
    #   ком. 2, с теми же OBJECTID; у города, улицы и дома есть закрытые прежние записи.
    # Плюс параметры (индекс, ОКТМО, официальное наименование; закрытые и истёкшие — для
    # фильтров) и данные, которые минимальный набор не загружает (участки, помещения, история
    # изменений), в том числе их строки в иерархиях.
    #
    # GUID объекта — Sample.guid(OBJECTID).
    module Sample
      VERSION    = "2026.01.16"
      DATES      = { "UPDATEDATE" => "2024-01-01", "STARTDATE" => "2024-01-01", "ENDDATE" => "2079-06-06" }.freeze
      ACTUAL     = { "ISACTUAL" => "1", "ISACTIVE" => "1" }.freeze
      CLOSED     = { "ISACTUAL" => "0", "ISACTIVE" => "0", "ENDDATE" => "2020-01-01" }.freeze
      DICTIONARY = { **DATES, "ISACTIVE" => "true" }.freeze

      class << self
        # OBJECTID → GUID: детерминированные, чтобы тесты могли их проверять
        def guid(object_id) = format("00000000-0000-4000-8000-%012d", object_id)

        # Справочники корня: имя таблицы (Gar::Schema) → записи
        def root = @root ||= dictionaries.freeze

        # Таблицы субъектов: код субъекта → имя таблицы → записи
        def regions
          @regions ||=
            begin
              @data = Hash.new { |regions, code| regions[code] = Hash.new { |tables, name| tables[name] = [] } }
              add_kirov
              add_komi
              add_moscow
              add_moscow_oblast
              @data.transform_values { |tables| tables.to_h { |name, records| [name, records.freeze] }.freeze }.freeze
                   .tap { @data = nil }
            end
        end

        # Набор как архив для Importer (без zip)
        def archive = MemoryArchive.new(version: VERSION, root:, regions:)

        private

        def dictionaries
          levels = { 1 => "Субъект РФ", 2 => "Административный район", 3 => "Муниципальный район", 5 => "Город",
                     6 => "Населенный пункт", 8 => "Элемент улично-дорожной сети", 10 => "Здание (строение), сооружение", 11 => "Помещение",
                     12 => "Помещение в пределах помещения" }
          object_types = [[1, 1, "обл", "Область"], [2, 1, "респ", "Республика"], [3, 1, "г", "Город"], [4, 3, "г.о.", "Городской округ"],
                          [5, 5, "г", "Город"], [6, 8, "ул", "Улица"], [7, 2, "г", "Город"], [8, 8, "пр-кт", "Проспект"],
                          [9, 6, "п", "Поселок"]]
          params = { 5 => "Почтовый индекс", 6 => "ОКАТО", 7 => "OKTMO", 16 => "Официальное наименование",
                     22 => "Административный центр субъекта РФ" }
          {
            object_levels:        levels.map { |level, name| { "LEVEL" => level, "NAME" => name, **DICTIONARY } },
            address_object_types: object_types.map { |id, level, short, name| { "ID" => id, "LEVEL" => level, **type_attributes(short, name) } },
            house_types:          types(2 => ["д.", "Дом"], 5 => ["зд.", "Здание"]),
            add_house_types:      types(1 => ["к.", "Корпус"], 2 => ["стр.", "Строение"], 4 => ["литера", "Литера"]),
            apartment_types:      types(2 => ["кв.", "Квартира"]),
            room_types:           types(1 => ["ком.", "Комната"]),
            param_types:          params.map { |id, name| { "ID" => id, "NAME" => name, "DESC" => name, "CODE" => "C#{id}", **DICTIONARY } }
          }
        end

        def add_kirov
          objects = [[4_300_001, "Кировская", "обл", 1], [4_300_002, "город Киров", "г.о.", 3], [4_300_003, "Киров", "г", 5],
                     [4_300_010, "Ленина", "ул", 8], [4_300_011, "Воровского", "ул", 8], [4_300_012, "Октябрьский", "пр-кт", 8],
                     [4_300_013, "Большая Садовая", "ул", 8], [4_300_020, "Кировский", "п", 6]]
          houses  = [
            house(4_300_101, "10"), house(4_300_102, "10а"), house(4_300_103, "10/2"),
            house(4_300_104, "12", "ADDNUM1" => "2", "ADDTYPE1" => 1),
            house(4_300_105, "12", "ADDNUM1" => "1", "ADDTYPE1" => 2),
            house(4_300_106, "14", "ADDNUM1" => "1", "ADDTYPE1" => 1, "ADDNUM2" => "3", "ADDTYPE2" => 2),
            house(4_300_107, "16", "ISACTIVE" => "0"),
            house(4_300_108, "18", "ADDNUM1" => "Б", "ADDTYPE1" => 4),
            house(4_300_201, "5")
          ]
          # Административная иерархия: город сразу под областью; муниципальная — через городской округ
          adm = { 4_300_003 => 4_300_001, 4_300_010 => 4_300_003, 4_300_011 => 4_300_003, 4_300_012 => 4_300_003, 4_300_013 => 4_300_003,
                  4_300_020 => 4_300_001 }
          houses.each { |record| adm[record["OBJECTID"]] = record["OBJECTID"] == 4_300_201 ? 4_300_011 : 4_300_010 }
          add_region("43", objects:, houses:, parents: { adm:, mun: adm.merge(4_300_002 => 4_300_001, 4_300_003 => 4_300_002) })

          # Прежнее название улицы Воровского — «Старая»; упразднённая улица Заводская (актуальная
          # запись недействующего объекта, без строк иерархии)
          add("43", :address_objects, address_object(4_300_011, "Старая", "ул", 8, "ID" => 9_300_011, **CLOSED, "NEXTID" => 4_300_011),
              address_object(4_300_014, "Заводская", "ул", 8, "ISACTIVE" => "0"))
          add("43", :addr_obj_params, param(1, 4_300_001, 16, "Кировская область"), param(2, 4_300_010, 5, "610000"),
              param(4, 4_300_003, 22, "1"), # Киров — административный центр субъекта
              param(3, 4_300_010, 5, "610001", "CHANGEIDEND" => 77, "ENDDATE" => "2020-01-01"))
          add("43", :house_params, param(11, 4_300_101, 5, "610017"), param(12, 4_300_101, 7, "33701000001"),
              param(13, 4_300_104, 5, "610017"),
              param(14, 4_300_101, 6, "33401000000", "ENDDATE" => "2025-01-01")) # истёк до выгрузки
          add_kirov_extras
        end

        # Участок на улице Ленина и квартира в доме 10 — со строками в обеих иерархиях; журнал изменений
        def add_kirov_extras
          add("43", :steads, object_record(4_300_901, "ID" => 1, "NUMBER" => "5"))
          add("43", :apartments, object_record(4_300_902, "ID" => 1, "NUMBER" => "1", "APARTTYPE" => 2))
          add("43", :stead_params, param(21, 4_300_901, 8, "43:40:000000:1"))
          parents = { 4_300_901 => "4300010", 4_300_902 => "4300010.4300101" }
          { adm_hierarchy: "4300001.4300003", mun_hierarchy: "4300001.4300002.4300003" }.each do |table, city|
            add("43", table, *parents.map { |object_id, ancestors| hierarchy_item(object_id, "#{city}.#{ancestors}.#{object_id}", "43") })
          end
          add("43", :change_history, { "CHANGEID" => 1, "OBJECTID" => 4_300_010, "ADROBJECTID" => guid(1), "OPERTYPEID" => 10,
                                       "CHANGEDATE" => "2024-01-01" })
        end

        def add_komi
          objects = [[1_100_001, "Коми", "респ", 1], [1_100_002, "Сыктывкар", "г.о.", 3], [1_100_003, "Сыктывкар", "г", 5],
                     [1_100_010, "Ленина", "ул", 8]]
          adm     = { 1_100_003 => 1_100_001, 1_100_010 => 1_100_003, 1_100_101 => 1_100_010 }
          add_region("11", objects:, houses: [house(1_100_101, "10")],
                           parents: { adm:, mun: adm.merge(1_100_002 => 1_100_001, 1_100_003 => 1_100_002) })
        end

        def add_moscow
          adm = { 7_700_010 => 7_700_001, 7_700_101 => 7_700_010 }
          add_region("77", objects: [[7_700_001, "Москва", "г", 1], [7_700_010, "Тверская", "ул", 8]], houses: [house(7_700_101, "1")],
                           parents: { adm:, mun: adm })
        end

        # Пример из правил ФНС. Административная иерархия в правилах не приведена: город
        # здесь — сразу под областью
        def add_moscow_oblast
          objects = [[807_356, "Московская", "обл", 1], [162_142_236, "Павлово-Посадский", "г.о.", 3, { "ID" => 1_087_892 }],
                     [815_937, "Павловский Посад", "г", 2, { "ID" => 52_095_543, "PREVID" => 815_937 }],
                     [828_325, "Тихонова", "ул", 8, { "ID" => 1_003_040, "PREVID" => 828_325 }]]
          houses  = [house(44_870_981, "93", "ID" => 69_095_652, "PREVID" => 44_870_981)]
          rooms   = { apartments: object_record(44_876_904, "ID" => 26_433_235, "NUMBER" => "17", "APARTTYPE" => 2),
                      rooms:      object_record(44_877_013, "ID" => 242_112, "NUMBER" => "2", "ROOMTYPE" => 1) }
          adm     = { 815_937 => 807_356, 828_325 => 815_937, 44_870_981 => 828_325, 44_876_904 => 44_870_981, 44_877_013 => 44_876_904 }
          mun     = adm.merge(162_142_236 => 807_356, 815_937 => 162_142_236)
          add_region("50", objects:, houses:, parents: { adm:, mun: }, extra: { 44_876_904 => 11, 44_877_013 => 12 })
          rooms.each { |table, record| add("50", table, record) }

          # Закрытые прежние записи: у города был другой уровень (5)
          add("50", :address_objects, address_object(815_937, "Павловский Посад", "г", 5, **CLOSED, "NEXTID" => 52_095_543),
              address_object(828_325, "Тихонова", "ул", 8, **CLOSED, "NEXTID" => 1_003_040))
          add("50", :houses, house(44_870_981, "93", **CLOSED, "NEXTID" => 69_095_652))
          add("50", :addr_obj_params, param(31, 807_356, 16, "Московская область"))
        end

        # objects — [OBJECTID, название, тип, уровень, (атрибуты)]; parents — карты «объект →
        # родитель» для :adm и :mun, объект без родителя — корень иерархии; extra — другие
        # объекты субъекта в иерархиях и реестре: OBJECTID → уровень
        def add_region(region, objects:, houses:, parents:, extra: {})
          add(region, :address_objects, *objects.map do |object_id, name, type, level, attributes|
            address_object(object_id, name, type, level, **attributes.to_h)
          end)
          add(region, :houses, *houses)
          ids = objects.map(&:first) + houses.map { _1["OBJECTID"] } + extra.keys
          { adm_hierarchy: parents[:adm], mun_hierarchy: parents[:mun] }.each { |table, map| add(region, table, *hierarchy(ids, map, region)) }
          levels = objects.to_h { [_1[0], _1[3]] }.merge(extra)
          add(region, :reestr_objects, *ids.map { reestr_object(_1, levels.fetch(_1, 10)) })
        end

        def add(region, table, *records) = @data[region][table].concat(records)

        def types(names) = names.map { |id, (short_name, name)| { "ID" => id, **type_attributes(short_name, name) } }

        def type_attributes(short_name, name) = { "SHORTNAME" => short_name, "NAME" => name, "DESC" => name, **DICTIONARY }

        # Общие атрибуты записи объекта: идентификаторы, даты, признаки актуальности
        def object_record(object_id, attributes)
          { "ID" => object_id, "OBJECTID" => object_id, "OBJECTGUID" => guid(object_id), "CHANGEID" => object_id, "OPERTYPEID" => 10,
            **DATES, **ACTUAL, **attributes }
        end

        def address_object(object_id, name, type_name, level, **attributes)
          object_record(object_id, { "NAME" => name, "TYPENAME" => type_name, "LEVEL" => level, **attributes })
        end

        def house(object_id, number, attributes = {}) = object_record(object_id, { "HOUSENUM" => number, "HOUSETYPE" => 2, **attributes })

        # Строки иерархии для объектов, которые в ней участвуют (есть родитель или потомки);
        # PATH собирается подъёмом по родителям до корня
        def hierarchy(object_ids, parents, region)
          object_ids.select { parents.key?(_1) || parents.value?(_1) }.map do |object_id|
            path = [object_id]
            path.unshift(parents[path.first]) while parents.key?(path.first)
            hierarchy_item(object_id, path.join("."), region)
          end
        end

        def hierarchy_item(object_id, path, region)
          { "ID" => object_id, "OBJECTID" => object_id, "PARENTOBJID" => path.split(".")[-2] || 0, "CHANGEID" => object_id,
            "REGIONCODE" => region, **DATES, "ISACTIVE" => "1", "PATH" => path }
        end

        def param(id, object_id, type_id, value, attributes = {})
          { "ID" => id, "OBJECTID" => object_id, "CHANGEID" => id, "CHANGEIDEND" => 0, "TYPEID" => type_id, "VALUE" => value,
            **DATES, **attributes }
        end

        def reestr_object(object_id, level)
          { "OBJECTID" => object_id, "OBJECTGUID" => guid(object_id), "CHANGEID" => object_id, "ISACTIVE" => "1", "LEVELID" => level,
            "CREATEDATE" => "2024-01-01", "UPDATEDATE" => "2024-01-01" }
        end
      end
    end
  end
end
