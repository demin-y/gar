# frozen_string_literal: true

require "zip"
require "securerandom"
require "fileutils"

# Хелпер для создания тестовых ZIP-архивов ГАР
# Формат соответствует реальной структуре архивов fias.nalog.ru
module GarArchiveHelper
  module_function

  # Создаёт минимальный тестовый архив ГАР
  #
  # @param version_id [Integer] версия архива (например, 20251106)
  # @param dir [String] директория для создания архива (по умолчанию tmpdir)
  # @return [String] путь к созданному ZIP-архиву
  def create_test_archive(version_id: 20_251_106, dir: nil)
    dir ||= Dir.mktmpdir("gar_test")
    zip_path = File.join(dir, "gar_xml_v#{version_id}.zip")

    Zip::File.open(zip_path, Zip::File::CREATE) do |zipfile|
      # Регион 01 (минимальный набор данных)
      add_address_objects(zipfile, "01", version_id)
      add_adm_hierarchy(zipfile, "01", version_id)
      add_mun_hierarchy(zipfile, "01", version_id)
      add_houses(zipfile, "01", version_id)
      add_reestr_objects(zipfile, "01", version_id)
    end

    zip_path
  end

  # Удаляет архив и распакованные файлы
  def cleanup(zip_path)
    return unless zip_path

    # Удаляем распакованную директорию
    extract_dir = File.join(File.dirname(zip_path), File.basename(zip_path, ".zip"))
    FileUtils.rm_rf(extract_dir)

    # Удаляем сам архив
    FileUtils.rm_f(zip_path)

    # Удаляем родительскую tmpdir если пустая
    parent_dir = File.dirname(zip_path)
    FileUtils.rmdir(parent_dir) if Dir.exist?(parent_dir) && Dir.empty?(parent_dir)
  rescue StandardError
    nil
  end

  # --- Генераторы XML для каждого типа сущности ---

  def add_address_objects(zipfile, region, version_id)
    uuid = SecureRandom.uuid
    xml = build_address_objects_xml
    zipfile.get_output_stream("#{region}/AS_ADDR_OBJ_#{version_id}_#{uuid}.XML") { |f| f.write(xml) }
  end

  def add_adm_hierarchy(zipfile, region, version_id)
    uuid = SecureRandom.uuid
    xml = build_adm_hierarchy_xml
    zipfile.get_output_stream("#{region}/AS_ADM_HIERARCHY_#{version_id}_#{uuid}.XML") { |f| f.write(xml) }
  end

  def add_mun_hierarchy(zipfile, region, version_id)
    uuid = SecureRandom.uuid
    xml = build_mun_hierarchy_xml
    zipfile.get_output_stream("#{region}/AS_MUN_HIERARCHY_#{version_id}_#{uuid}.XML") { |f| f.write(xml) }
  end

  def add_houses(zipfile, region, version_id)
    uuid = SecureRandom.uuid
    xml = build_houses_xml
    zipfile.get_output_stream("#{region}/AS_HOUSES_#{version_id}_#{uuid}.XML") { |f| f.write(xml) }
  end

  def add_reestr_objects(zipfile, region, version_id)
    uuid = SecureRandom.uuid
    xml = build_reestr_objects_xml
    zipfile.get_output_stream("#{region}/AS_REESTR_OBJECTS_#{version_id}_#{uuid}.XML") { |f| f.write(xml) }
  end

  # --- XML builders ---

  def build_address_objects_xml
    # Формат без переносов строк (как в реальных файлах)
    <<~XML.delete("\n")
      <?xml version="1.0" encoding="utf-8"?>
      <ADDRESSOBJECTS>
      <OBJECT ID="1" OBJECTID="1001" OBJECTGUID="#{SecureRandom.uuid}" CHANGEID="1"
       NAME="Тестовый регион" TYPENAME="обл" LEVEL="1" OPERTYPEID="1"
       PREVID="0" NEXTID="0" UPDATEDATE="2024-12-01" STARTDATE="1900-01-01"
       ENDDATE="2079-06-06" ISACTUAL="1" ISACTIVE="1" />
      <OBJECT ID="2" OBJECTID="1002" OBJECTGUID="#{SecureRandom.uuid}" CHANGEID="2"
       NAME="Тестовый город" TYPENAME="г" LEVEL="5" OPERTYPEID="1"
       PREVID="0" NEXTID="0" UPDATEDATE="2024-12-01" STARTDATE="1900-01-01"
       ENDDATE="2079-06-06" ISACTUAL="1" ISACTIVE="1" />
      <OBJECT ID="3" OBJECTID="1003" OBJECTGUID="#{SecureRandom.uuid}" CHANGEID="3"
       NAME="Центральная" TYPENAME="ул" LEVEL="8" OPERTYPEID="1"
       PREVID="0" NEXTID="0" UPDATEDATE="2024-12-01" STARTDATE="1900-01-01"
       ENDDATE="2079-06-06" ISACTUAL="1" ISACTIVE="1" />
      </ADDRESSOBJECTS>
    XML
  end

  def build_adm_hierarchy_xml
    <<~XML.delete("\n")
      <?xml version="1.0" encoding="utf-8"?>
      <ITEMS>
      <ITEM ID="1" OBJECTID="1001" PARENTOBJID="0" CHANGEID="1"
       REGIONCODE="01" AREACODE="" CITYCODE="" PLACECODE="" PLANCODE="" STREETCODE=""
       PREVID="0" NEXTID="0" UPDATEDATE="2024-12-01" STARTDATE="1900-01-01"
       ENDDATE="2079-06-06" ISACTIVE="1" PATH="1001" />
      <ITEM ID="2" OBJECTID="1002" PARENTOBJID="1001" CHANGEID="2"
       REGIONCODE="01" AREACODE="" CITYCODE="001" PLACECODE="" PLANCODE="" STREETCODE=""
       PREVID="0" NEXTID="0" UPDATEDATE="2024-12-01" STARTDATE="1900-01-01"
       ENDDATE="2079-06-06" ISACTIVE="1" PATH="1001.1002" />
      <ITEM ID="3" OBJECTID="1003" PARENTOBJID="1002" CHANGEID="3"
       REGIONCODE="01" AREACODE="" CITYCODE="001" PLACECODE="" PLANCODE="" STREETCODE="0001"
       PREVID="0" NEXTID="0" UPDATEDATE="2024-12-01" STARTDATE="1900-01-01"
       ENDDATE="2079-06-06" ISACTIVE="1" PATH="1001.1002.1003" />
      </ITEMS>
    XML
  end

  def build_mun_hierarchy_xml
    <<~XML.delete("\n")
      <?xml version="1.0" encoding="utf-8"?>
      <ITEMS>
      <ITEM ID="1" OBJECTID="1001" PARENTOBJID="0" CHANGEID="1"
       OKTMO="01000000" PREVID="0" NEXTID="0" UPDATEDATE="2024-12-01"
       STARTDATE="1900-01-01" ENDDATE="2079-06-06" ISACTIVE="1" PATH="1001" />
      <ITEM ID="2" OBJECTID="1002" PARENTOBJID="1001" CHANGEID="2"
       OKTMO="01000001" PREVID="0" NEXTID="0" UPDATEDATE="2024-12-01"
       STARTDATE="1900-01-01" ENDDATE="2079-06-06" ISACTIVE="1" PATH="1001.1002" />
      </ITEMS>
    XML
  end

  def build_houses_xml
    <<~XML.delete("\n")
      <?xml version="1.0" encoding="utf-8"?>
      <HOUSES>
      <HOUSE ID="1" OBJECTID="2001" OBJECTGUID="#{SecureRandom.uuid}" CHANGEID="1"
       HOUSENUM="1" HOUSETYPE="2" OPERTYPEID="1"
       PREVID="0" NEXTID="0" UPDATEDATE="2024-12-01" STARTDATE="1900-01-01"
       ENDDATE="2079-06-06" ISACTUAL="1" ISACTIVE="1" />
      <HOUSE ID="2" OBJECTID="2002" OBJECTGUID="#{SecureRandom.uuid}" CHANGEID="2"
       HOUSENUM="2" ADDNUM1="А" HOUSETYPE="2" OPERTYPEID="1"
       PREVID="0" NEXTID="0" UPDATEDATE="2024-12-01" STARTDATE="1900-01-01"
       ENDDATE="2079-06-06" ISACTUAL="1" ISACTIVE="1" />
      </HOUSES>
    XML
  end

  def build_reestr_objects_xml
    <<~XML.delete("\n")
      <?xml version="1.0" encoding="utf-8"?>
      <REESTR_OBJECTS>
      <OBJECT OBJECTID="1001" OBJECTGUID="#{SecureRandom.uuid}" CHANGEID="1"
       LEVELID="1" CREATEDATE="2024-01-01" UPDATEDATE="2024-12-01" ISACTIVE="1" />
      <OBJECT OBJECTID="1002" OBJECTGUID="#{SecureRandom.uuid}" CHANGEID="2"
       LEVELID="5" CREATEDATE="2024-01-01" UPDATEDATE="2024-12-01" ISACTIVE="1" />
      <OBJECT OBJECTID="1003" OBJECTGUID="#{SecureRandom.uuid}" CHANGEID="3"
       LEVELID="8" CREATEDATE="2024-01-01" UPDATEDATE="2024-12-01" ISACTIVE="1" />
      <OBJECT OBJECTID="2001" OBJECTGUID="#{SecureRandom.uuid}" CHANGEID="4"
       LEVELID="10" CREATEDATE="2024-01-01" UPDATEDATE="2024-12-01" ISACTIVE="1" />
      <OBJECT OBJECTID="2002" OBJECTGUID="#{SecureRandom.uuid}" CHANGEID="5"
       LEVELID="10" CREATEDATE="2024-01-01" UPDATEDATE="2024-12-01" ISACTIVE="1" />
      </REESTR_OBJECTS>
    XML
  end
end

if defined?(RSpec)
  RSpec.configure do |config|
    config.include GarArchiveHelper
  end
end
