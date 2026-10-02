# frozen_string_literal: true

# Цельный синтетический набор ГАР для сквозных тестов:
# - 43 Кировская обл. → (г.о. город Киров) → г. Киров → ул. Ленина (дома 10, 10а, 10/2, 12 к. 2,
#   12 стр. 1, 14 к. 1 стр. 3, снесённый 16) и ул. Воровского (бывш. Старая, дом 5);
# - 11 Республика Коми → Сыктывкар → ул. Ленина, дом 10 (та же улица в другом субъекте);
# - 77 Москва → ул. Тверская, дом 1;
# - 80 — пустой субъект (все 18 файлов без записей).
# Плюс параметры (индекс, ОКТМО, официальное наименование) и «шум» из таблиц,
# которые гем не импортирует (участки, помещения, история изменений).
module GarSampleArchive
  module_function

  DATES      = { "UPDATEDATE" => "2024-01-01", "STARTDATE" => "2024-01-01", "ENDDATE" => "2079-06-06" }.freeze
  ACTUAL     = { "ISACTUAL" => "1", "ISACTIVE" => "1" }.freeze
  DICTIONARY = { **DATES, "ISACTIVE" => "true" }.freeze

  # OBJECTID → GUID: детерминированные, чтобы тесты могли их проверять
  def guid(object_id)
    format("00000000-0000-4000-8000-%012d", object_id)
  end

  def build
    builder = GarArchiveBuilder.new
    add_dictionaries(builder)
    add_kirov(builder)
    add_komi(builder)
    add_moscow(builder)
    builder.region("80")
  end

  def add_dictionaries(builder)
    builder.root(:object_levels,
                 *{ 1 => "Субъект РФ", 3 => "Муниципальный район", 5 => "Город",
                    8 => "Элемент улично-дорожной сети", 10 => "Здание (строение), сооружение" }
                   .map { |level, name| { "LEVEL" => level, "NAME" => name, **DICTIONARY } })

    builder.root(:addr_obj_types,
                 *[[1, 1, "обл", "Область"], [2, 1, "респ", "Республика"], [3, 1, "г", "Город"],
                   [4, 3, "г.о.", "Городской округ"], [5, 5, "г", "Город"], [6, 8, "ул", "Улица"]]
                   .map { |id, level, short, name| { "ID" => id, "LEVEL" => level, **type_attributes(short, name) } })

    builder.root(:house_types, *{ 2 => ["д.", "Дом"], 5 => ["зд.", "Здание"] }.map { |id, names| { "ID" => id, **type_attributes(*names) } })
    builder.root(:addhouse_types, *{ 1 => ["к.", "Корпус"], 2 => ["стр.", "Строение"] }.map { |id, names| { "ID" => id, **type_attributes(*names) } })

    builder.root(:param_types,
                 *{ 5 => "Почтовый индекс", 6 => "ОКАТО", 7 => "OKTMO", 16 => "Официальное наименование" }
                   .map { |id, name| { "ID" => id, "NAME" => name, "DESC" => name, "CODE" => "C#{id}", **DICTIONARY } })
  end

  def add_kirov(builder)
    objects = [
      [4_300_001, "Кировская", "обл", 1],
      [4_300_002, "город Киров", "г.о.", 3],
      [4_300_003, "Киров", "г", 5],
      [4_300_010, "Ленина", "ул", 8],
      [4_300_011, "Воровского", "ул", 8]
    ]
    houses = [
      house(4_300_101, "10"),
      house(4_300_102, "10а"),
      house(4_300_103, "10/2"),
      house(4_300_104, "12", "ADDNUM1" => "2", "ADDTYPE1" => 1),
      house(4_300_105, "12", "ADDNUM1" => "1", "ADDTYPE1" => 2),
      house(4_300_106, "14", "ADDNUM1" => "1", "ADDTYPE1" => 1, "ADDNUM2" => "3", "ADDTYPE2" => 2),
      house(4_300_107, "16", "ISACTIVE" => "0"),
      house(4_300_201, "5")
    ]
    # Административная иерархия: город сразу под областью; муниципальная — через городской округ
    adm = { 4_300_003 => 4_300_001, 4_300_010 => 4_300_003, 4_300_011 => 4_300_003 }
    houses.each { |record| adm[record["OBJECTID"]] = record["OBJECTID"] == 4_300_201 ? 4_300_011 : 4_300_010 }
    mun = adm.merge(4_300_002 => 4_300_001, 4_300_003 => 4_300_002)

    add_region(builder, "43", objects:, houses:, parents: { adm:, mun: })
    # Историческая запись улицы Воровского: прежнее название «Старая»
    builder.region("43", :addr_obj,
                   address_object(4_300_011, "Старая", "ул", 8, "ID" => 9_300_011, "ISACTUAL" => "0", "ISACTIVE" => "0",
                                                                "ENDDATE" => "2020-01-01", "NEXTID" => 4_300_011))
    builder.region("43", :addr_obj_params,
                   param(1, 4_300_001, 16, "Кировская область"),
                   param(2, 4_300_010, 5, "610000"),
                   param(3, 4_300_010, 5, "610001", "CHANGEIDEND" => 77, "ENDDATE" => "2020-01-01"))
    builder.region("43", :houses_params,
                   param(11, 4_300_101, 5, "610017"),
                   param(12, 4_300_101, 7, "33701000001"),
                   param(13, 4_300_104, 5, "610017"))
    add_noise(builder, "43")
  end

  def add_komi(builder)
    objects = [[1_100_001, "Коми", "респ", 1], [1_100_002, "Сыктывкар", "г.о.", 3], [1_100_003, "Сыктывкар", "г", 5], [1_100_010, "Ленина", "ул", 8]]
    adm     = { 1_100_003 => 1_100_001, 1_100_010 => 1_100_003, 1_100_101 => 1_100_010 }
    mun     = adm.merge(1_100_002 => 1_100_001, 1_100_003 => 1_100_002)
    add_region(builder, "11", objects:, houses: [house(1_100_101, "10")], parents: { adm:, mun: })
  end

  def add_moscow(builder)
    objects = [[7_700_001, "Москва", "г", 1], [7_700_010, "Тверская", "ул", 8]]
    adm     = { 7_700_010 => 7_700_001, 7_700_101 => 7_700_010 }
    add_region(builder, "77", objects:, houses: [house(7_700_101, "1")], parents: { adm:, mun: adm })
  end

  # parents — карты «объект → родитель» для :adm и :mun; объект без родителя — корень иерархии
  def add_region(builder, region, objects:, houses:, parents:)
    ids = objects.map(&:first) + houses.map { |record| record["OBJECTID"] }
    builder.region(region, :addr_obj, *objects.map { |args| address_object(*args) })
    builder.region(region, :houses, *houses)
    builder.region(region, :adm_hierarchy, *hierarchy(ids, parents[:adm], region))
    builder.region(region, :mun_hierarchy, *hierarchy(ids, parents[:mun], region))
    levels = objects.to_h { |id, *, level| [id, level] }
    builder.region(region, :reestr_objects, *ids.map { |id| reestr_object(id, levels.fetch(id, 10)) })
  end

  def add_noise(builder, region)
    builder.region(region, :steads, { "ID" => 1, "OBJECTID" => 4_300_901, "OBJECTGUID" => guid(4_300_901), "CHANGEID" => 1,
                                      "NUMBER" => "5", "OPERTYPEID" => 10, **DATES, **ACTUAL })
    builder.region(region, :apartments, { "ID" => 1, "OBJECTID" => 4_300_902, "OBJECTGUID" => guid(4_300_902), "CHANGEID" => 1,
                                          "NUMBER" => "1", "APARTTYPE" => 2, "OPERTYPEID" => 10, **DATES, **ACTUAL })
    builder.region(region, :steads_params, param(21, 4_300_901, 8, "43:40:000000:1"))
    builder.region(region, :change_history, { "CHANGEID" => 1, "OBJECTID" => 4_300_010, "ADROBJECTID" => guid(1),
                                              "OPERTYPEID" => 10, "CHANGEDATE" => "2024-01-01" })
  end

  def type_attributes(short_name, name)
    { "SHORTNAME" => short_name, "NAME" => name, "DESC" => name, **DICTIONARY }
  end

  def address_object(object_id, name, type_name, level, overrides = {})
    { "ID" => object_id, "OBJECTID" => object_id, "OBJECTGUID" => guid(object_id), "CHANGEID" => object_id, "NAME" => name,
      "TYPENAME" => type_name, "LEVEL" => level, "OPERTYPEID" => 10, **DATES, **ACTUAL }.merge(overrides)
  end

  def house(object_id, number, overrides = {})
    { "ID" => object_id, "OBJECTID" => object_id, "OBJECTGUID" => guid(object_id), "CHANGEID" => object_id,
      "HOUSENUM" => number, "HOUSETYPE" => 2, "OPERTYPEID" => 10, **DATES, **ACTUAL }.merge(overrides)
  end

  # Строки иерархии для объектов, которые в ней участвуют (есть родитель или потомки);
  # PATH собирается подъёмом по родителям до корня
  def hierarchy(object_ids, parents, region)
    object_ids.select { |id| parents.key?(id) || parents.value?(id) }.map do |object_id|
      path = [object_id]
      path.unshift(parents[path.first]) while parents.key?(path.first)
      { "ID" => object_id, "OBJECTID" => object_id, "PARENTOBJID" => parents.fetch(object_id, 0), "CHANGEID" => object_id,
        "REGIONCODE" => region, **DATES, "ISACTIVE" => "1", "PATH" => path.join(".") }
    end
  end

  def param(id, object_id, type_id, value, overrides = {})
    { "ID" => id, "OBJECTID" => object_id, "CHANGEID" => id, "CHANGEIDEND" => 0, "TYPEID" => type_id,
      "VALUE" => value, **DATES }.merge(overrides)
  end

  def reestr_object(object_id, level)
    { "OBJECTID" => object_id, "OBJECTGUID" => guid(object_id), "CHANGEID" => object_id, "ISACTIVE" => "1",
      "LEVELID" => level, "CREATEDATE" => "2024-01-01", "UPDATEDATE" => "2024-01-01" }
  end
end
