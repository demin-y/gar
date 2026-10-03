# frozen_string_literal: true

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
  # элемент («Ленина ул», «д. 10»), address — полный путь по иерархии запроса
  Suggestion =
    Data.define(:kind, :object_guid, :gar_object_id, :level, :region_code, :name, :address) do
      include Serializable
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

  # Разобранный адрес (Gar.address). Части — полные наименования элементов пути («Кировская
  # область», «город Киров», «улица Ленина»); house — номер с литерой или дробью, building и
  # structure — номера корпуса и строения. parent_guids — GUID элементов пути от субъекта до
  # родителя. full_address — строка по правилам ФНС (полные типы), short_address — то же с
  # краткими типами («г Киров, ул Ленина, д. 10»)
  Address =
    Data.define(:object_guid, :gar_object_id, :level, :hierarchy, :region_code, :region, :district, :city, :street,
                :house, :building, :structure, :postal_code, :okato, :oktmo, :parent_guids, :full_address, :short_address) do
      include Serializable
    end
end
