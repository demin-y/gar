# frozen_string_literal: true

require "date"
require "json"

module Gar
  # Результаты — Data: as_json и to_json дают Hash с ключами-строками (вложенные результаты —
  # тоже), их можно отдать в JSON как есть
  module Serializable
    def self.json(value)
      case value
      when Serializable then value.as_json
      when Array then value.map { json(_1) }
      else value
      end
    end

    def as_json(*) = to_h.to_h { |key, value| [key.to_s, Serializable.json(value)] }
    def to_json(*) = as_json.to_json(*)
  end

  # Адресный объект (регион, город, улица…) в результатах поиска. gar_object_id — OBJECTID ГАР
  # (устойчивый идентификатор объекта; object_id занят Ruby), id — идентификатор записи,
  # region_code — код субъекта («43»), active — объект действует (недействующие отдаёт только
  # Search#find_address_objects_by_guids)
  AddressObject =
    Data.define(:id, :gar_object_id, :object_guid, :name, :type_name, :level, :region_code, :active, :full_adm_path,
                :full_mun_path) do
      include Serializable

      def self.from_row(row)
        new(id: row["id"].to_i, gar_object_id: row["object_id"].to_i, object_guid: row["object_guid"], name: row["name"],
            type_name: row["type_name"], level: row["level"]&.to_i, region_code: row["region_code"], active: row["is_active"] == "t",
            full_adm_path: row["full_adm_path"], full_mun_path: row["full_mun_path"])
      end
    end

  # Дом в результатах поиска; house_type — краткий тип («д.», «зд.»)
  House =
    Data.define(:id, :gar_object_id, :object_guid, :house_num, :house_type, :region_code, :full_adm_path, :full_mun_path) do
      include Serializable

      def self.from_row(row)
        new(id: row["id"].to_i, gar_object_id: row["object_id"].to_i, object_guid: row["object_guid"], house_num: row["house_num"],
            house_type: row["house_type"], region_code: row["region_code"], full_adm_path: row["full_adm_path"],
            full_mun_path: row["full_mun_path"])
      end
    end

  # Элемент автодополнения (Gar.autocomplete): kind — :house или :address_object; name — сам
  # элемент («Ленина ул», «д. 10»), address — полный путь по иерархии запроса; exact — дом с
  # введённым номером целиком, как :exact у Gar.match_house: номер с литерой, корпус и строение
  # совпали, других дополнительных номеров нет («13» — не «13а» и не «13 к. 1»)
  Suggestion =
    Data.define(:kind, :object_guid, :gar_object_id, :level, :region_code, :name, :address, :exact) do
      include Serializable

      def initialize(exact: false, **) = super
    end

  # Дом, сопоставленный старой записи адреса (Gar.match_house): status — :exact (номер, корпус
  # и строение совпали), :fuzzy (единственный дом с тем же номером, у которого есть корпус или
  # строение сверх записанных) или :none; house — найденный Gar::House или nil; alternatives —
  # другие дома улицы с тем же числом в номере («10а», «10/2» для «10»)
  HouseMatch =
    Data.define(:status, :house, :alternatives) do
      include Serializable
    end

  # Итог Gar.update!: kind — :none (база уже последней версии), :delta (применены дельты
  # versions) или :full (полный импорт версии to_version); from_version — версия до обновления
  # (nil — базы не было); reason — почему полный импорт («настройки загрузки … не совпадают»)
  UpdateResult =
    Data.define(:kind, :from_version, :to_version, :versions, :reason) do
      include Serializable

      def initialize(reason: nil, **) = super
    end

  # Применённая дельта из журнала gar_updates схемы (Gar::Delta.history): версия и дата
  # выгрузки, время применения, сколько записей добавлено или изменено и удалено
  DeltaUpdate =
    Data.define(:version_id, :version_date, :applied_at, :upserted, :deleted, :gem_version) do
      include Serializable
    end

  # Схема ГАР в базе (Gar.status): имя, сведения gar_meta (nil — схема без неё), место на диске в байтах
  SchemaInfo =
    Data.define(:name, :meta, :size) do
      include Serializable
    end

  # Состояние базы (Gar.status): текущая схема (nil — её нет), последние дельты текущей схемы,
  # резервные схемы (новые первыми) и схемы импорта — Gar::SchemaInfo
  Status =
    Data.define(:current, :updates, :backups, :imports) do
      include Serializable
    end

  # Элемент пути разобранного адреса (Gar::Address#elements). name — название без типа
  # («Киров»), short_type — краткий тип как в выгрузке («г», «ул.»: ГАР меняет их между
  # версиями), full_type — полный тип из справочника в нижнем регистре («город»). short_name и
  # full_name — элемент с типом («ул Ленина», «улица Ленина»); у субъекта, муниципального района и
  # поселения — действующее официальное наименование, если оно есть («Кировская область»)
  AddressElement =
    Data.define(:gar_object_id, :object_guid, :level, :name, :short_type, :full_type, :short_name, :full_name) do
      include Serializable
    end

  # Дополнительный номер дома с типом (Gar::HouseElement#additions): «к.», «корпус», «1»
  HouseAddition =
    Data.define(:short_type, :full_type, :number) do
      include Serializable
    end

  # Дом разобранного адреса (Gar::Address#house_element). number — номер с литерой в регистре
  # ГАР («18» с литерой «Б» — «18Б»); short_type и full_type — тип дома («соор.»,
  # «сооружение»); additions — остальные дополнительные номера (Gar::HouseAddition: корпус,
  # строение, сооружение…); short_name и full_name — тип и все номера («д. 18 литера Б»)
  HouseElement =
    Data.define(:number, :short_type, :full_type, :additions, :short_name, :full_name) do
      include Serializable
    end

  # Состояние объекта по GUID (Gar.address_status): status — :active (действует: Gar.address
  # соберёт его, если у объекта есть строка в иерархии запроса),
  # :inactive (актуальная запись ГАР с ISACTIVE = 0: объект снесён или упразднён) или
  # :not_found (такого GUID нет в схеме или он некорректен — остальные поля nil). level — уровень
  # (дом — 10), update_date и end_date — даты актуальной записи, operation_type_id и operation —
  # тип последней операции и его имя из справочника operation_types (nil — справочник пуст)
  AddressStatus =
    Data.define(:object_guid, :status, :gar_object_id, :level, :update_date, :end_date, :operation_type_id, :operation) do
      include Serializable

      def self.not_found(object_guid) = new(object_guid:, status: :not_found, **(members - [:object_guid, :status]).to_h { [_1, nil] })

      # Актуальная запись объекта или дома: object_id, level, is_active, даты, oper_type_id, operation
      def self.from_row(object_guid, row)
        date = ->(value) { value && Date.iso8601(value) }
        new(object_guid:, status: row["is_active"] == "t" ? :active : :inactive, gar_object_id: row["object_id"].to_i,
            level: row["level"].to_i, update_date: date.call(row["update_date"]), end_date: date.call(row["end_date"]),
            operation_type_id: row["oper_type_id"]&.to_i, operation: row["operation"])
      end
    end

  # Разобранный адрес (Gar.address). Части — полные наименования элементов пути («Кировская
  # область», «город Киров», «улица Ленина»); house — номер с литерой или дробью («10/2», «18Б»),
  # building и structure — номера корпуса и строения, house_element — дом целиком
  # (Gar::HouseElement: тип и все дополнительные номера; nil — объект не дом). parent_guids — GUID
  # элементов пути от субъекта до родителя. elements — Gar::AddressElement адресных объектов
  # адреса: от субъекта до родителя дома или до самого адресного объекта. city_guid и
  # street_guid — GUID элементов city и street (city_element и street_element — сами элементы).
  # Улица — самый глубокий элемент уровня 7 (планировочная структура: СНТ, микрорайон,
  # территория) или 8 (улично-дорожная сеть): дом на улице внутри СНТ — улица, дом в СНТ без
  # улицы — само СНТ. full_address — строка по правилам ФНС (полные типы), short_address — то же
  # с краткими типами («г Киров, ул Ленина, д. 10»)
  Address =
    Data.define(:object_guid, :gar_object_id, :level, :hierarchy, :region_code, :region, :district, :city, :city_guid, :street,
                :street_guid, :house, :building, :structure, :house_element, :postal_code, :okato, :oktmo, :parent_guids, :elements,
                :full_address, :short_address) do
      include Serializable

      def city_element = element(city_guid)
      def street_element = element(street_guid)

      private

      def element(guid) = guid && elements.find { _1.object_guid == guid }
    end
end
