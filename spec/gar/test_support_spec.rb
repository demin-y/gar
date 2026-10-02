# frozen_string_literal: true

RSpec.describe Gar::TestSupport, :db do
  let(:schema) { isolated_schema("gar_fixtures") }

  def guid(object_id) = Gar::TestSupport::Sample.guid(object_id)

  describe ".load_fixtures" do
    it "загружает набор как импорт: таблицы минимального набора, gar_meta, пути; соединение открывает сам" do
      expect(described_class.load_fixtures(schema:)).to eq(schema)

      expect(tables_in(schema)).to include(:address_objects, :houses, :adm_hierarchy, :house_params, :gar_meta)
        .and exclude(:apartments, :steads)
      expect(Gar::Meta.read(db_connection, schema)).to have_attributes(version_id: 20_260_116, status: "ready")
      expect(Gar::Search.new(schema:).find_house_by_guid(guid(4_300_106)).full_adm_path)
        .to eq("Кировская обл, Киров г, Ленина ул, д. 14 к. 1 стр. 3")
      expect(schema_exists?("#{schema}_fixtures_load")).to be(false)
    end

    it "содержит цепочку из правил ФНС с теми же OBJECTID" do
      Gar.configuration.preset = :extended
      described_class.load_fixtures(db_connection, schema:)

      house = Gar::Search.new(schema:).find_house_by_guid(guid(44_870_981))
      expect(house).to have_attributes(id: 69_095_652, house_num: "93",
                                       full_mun_path: "Московская обл, Павлово-Посадский г.о., Павловский Посад г, Тихонова ул, д. 93")
      room_path = db_connection.exec("SELECT path FROM #{schema}.mun_hierarchy WHERE object_id = 44877013").getvalue(0, 0)
      expect(room_path).to eq("807356.162142236.815937.828325.44870981.44876904.44877013")
      expect(table_count(schema, "rooms")).to eq(1)
    end

    it "учитывает настройки импорта: субъекты и иерархии" do
      Gar.configure do |config|
        config.region_codes = ["43"]
        config.hierarchies  = [:adm]
      end

      described_class.load_fixtures(db_connection, schema:)

      expect(db_connection.exec("SELECT DISTINCT region_code FROM #{schema}.houses").column_values(0)).to eq(["43"])
      expect(tables_in(schema)).to exclude(:mun_hierarchy)
    end

    it "заменяет схему, которую загрузил сам, и пустую" do
      db_connection.exec("CREATE SCHEMA #{schema}")
      described_class.load_fixtures(db_connection, schema:)
      db_connection.exec("DELETE FROM #{schema}.houses")

      described_class.load_fixtures(db_connection, schema:)

      expect(table_count(schema, "houses")).to eq(12)
    end

    it "не трогает схему с другими данными" do
      db_connection.exec("CREATE SCHEMA #{schema}; CREATE TABLE #{schema}.houses (id int); INSERT INTO #{schema}.houses VALUES (1)")

      expect { described_class.load_fixtures(db_connection, schema:) }.to raise_error(Gar::ConfigurationError, /загрузил не Gar::TestSupport/)
      expect(tables_in(schema)).to eq([:houses])
      expect(table_count(schema, "houses")).to eq(1)
    end
  end
end
