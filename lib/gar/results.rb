# frozen_string_literal: true

module Gar
  # Адресный объект (регион, город, улица…) в результатах поиска. gar_object_id — OBJECTID ГАР
  # (устойчивый идентификатор объекта; object_id занят Ruby), id — идентификатор записи
  AddressObject =
    Data.define(:id, :gar_object_id, :object_guid, :name, :type_name, :level, :full_adm_path, :full_mun_path) do
      def self.from_row(row)
        new(id: row["id"].to_i, gar_object_id: row["object_id"].to_i, object_guid: row["object_guid"], name: row["name"],
            type_name: row["type_name"], level: row["level"]&.to_i, full_adm_path: row["full_adm_path"],
            full_mun_path: row["full_mun_path"])
      end
    end

  # Дом в результатах поиска; house_type — краткий тип («д.», «зд.»)
  House =
    Data.define(:id, :gar_object_id, :object_guid, :house_num, :house_type, :full_adm_path, :full_mun_path) do
      def self.from_row(row)
        new(id: row["id"].to_i, gar_object_id: row["object_id"].to_i, object_guid: row["object_guid"], house_num: row["house_num"],
            house_type: row["house_type"], full_adm_path: row["full_adm_path"], full_mun_path: row["full_mun_path"])
      end
    end
end
