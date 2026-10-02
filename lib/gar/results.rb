# frozen_string_literal: true

require "json"

module Gar
  # Результаты — Data: to_h, as_json и to_json дают Hash с ключами-строками, их можно отдать
  # в JSON как есть
  module Serializable
    def as_json(*) = to_h.transform_keys(&:to_s)
    def to_json(*) = as_json.to_json(*)
  end

  # Адресный объект (регион, город, улица…) в результатах поиска. gar_object_id — OBJECTID ГАР
  # (устойчивый идентификатор объекта; object_id занят Ruby), id — идентификатор записи,
  # region_code — код субъекта («43»)
  AddressObject =
    Data.define(:id, :gar_object_id, :object_guid, :name, :type_name, :level, :region_code, :full_adm_path, :full_mun_path) do
      include Serializable

      def self.from_row(row)
        new(id: row["id"].to_i, gar_object_id: row["object_id"].to_i, object_guid: row["object_guid"], name: row["name"],
            type_name: row["type_name"], level: row["level"]&.to_i, region_code: row["region_code"],
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
