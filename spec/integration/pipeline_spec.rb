# frozen_string_literal: true

# Сквозной конвейер: архив → импорт → пути → поиск → переключение схем. Страховочная сетка
# рефакторинга (заведена в этапе 0 как характеризация 1.0.0). Ошибки из анализа
# (docs/rails_integration_plan.md) описаны как pending с номером: после исправления
# pending-пример «упадёт» — пометку нужно снять.
RSpec.describe "Конвейер ГАР на синтетическом архиве", :db do
  include_context "с синтетическим архивом"

  let(:importer)      { Gar::Importer.new(db_connection) }
  let(:import_schema) { "gar_v20260116" }

  def guid(object_id)
    GarSampleArchive.guid(object_id)
  end

  def import_with_paths
    importer.import_full_base(zip_path).tap { |schema| Gar::PathBuilder.new(db_connection, schema:).build }
  end

  def column_by_object(schema, table, column)
    db_connection.exec("SELECT object_id, #{column} FROM #{schema}.#{table}")
                 .to_h { |row| [row["object_id"].to_i, row[column]] }
  end

  before { register_schema_for_cleanup(import_schema) }

  describe "импорт" do
    it "создаёт версионную схему со справочниками и таблицами минимального набора" do
      expect(importer.import_full_base(zip_path)).to eq("gar_v20260116")

      counts = Gar.configuration.import_tables.to_h { |table| [table.name, table_count(import_schema, table.name)] }
      expect(counts).to eq(
        object_levels: 5, address_object_types: 6, house_types: 2, add_house_types: 2, apartment_types: 0, room_types: 0,
        operation_types: 0, param_types: 4, normative_docs_kinds: 0, normative_docs_types: 0,
        address_objects: 11, addr_obj_params: 2, adm_hierarchy: 19, mun_hierarchy: 21, houses: 10, house_params: 3
      )
    end

    it "проставляет код субъекта из имени папки, в том числе в муниципальной иерархии" do
      importer.import_full_base(zip_path)

      ["address_objects", "houses", "adm_hierarchy", "mun_hierarchy"].each do |table|
        regions = db_connection.exec("SELECT DISTINCT region_code FROM #{import_schema}.#{table}").column_values(0)
        expect(regions).to contain_exactly("43", "11", "77")
      end
    end

    it "сохраняет версию в database_version и не распаковывает архив на диск" do
      importer.import_full_base(zip_path)

      version = db_connection.exec("SELECT version_id FROM #{import_schema}.database_version").getvalue(0, 0)
      expect(version).to eq("20260116")
      expect(Dir.children(archive_dir)).to eq([File.basename(zip_path)])
    end

    it "загружает только актуальные записи, недействующие объекты оставляет" do
      importer.import_full_base(zip_path)

      expect(column_by_object(import_schema, "address_objects", "name").values).not_to include("Старая")
      expect(column_by_object(import_schema, "houses", "is_active")[4_300_107]).to eq("f")
    end

    it "после параллельного импорта в процессах соединение родителя остаётся рабочим" do
      skip "fork недоступен" unless Process.respond_to?(:fork)
      Gar.configuration.parallel_import          = true
      Gar.configuration.parallel_import_strategy = :processes

      importer.import_full_base(zip_path)

      expect(db_connection.exec("SELECT 1").getvalue(0, 0)).to eq("1")
      expect(importer.db_conn.exec("SELECT 1").getvalue(0, 0)).to eq("1")
      expect(table_count(import_schema, "houses")).to eq(10)
    end

    it "импортирует действующие параметры нужных типов из файлов *_PARAMS (ошибка 2)" do
      importer.import_full_base(zip_path)

      expect(column_by_object(import_schema, "addr_obj_params", "value")).to eq(4_300_001 => "Кировская область", 4_300_010 => "610000")
      expect(table_count(import_schema, "house_params")).to eq(3)
    end

    it "берёт версию из version.txt, а не из имени zip (ошибка 6)" do
      zip = archive_builder.write(archive_dir, name: "gar_xml.zip")

      expect(importer.import_full_base(zip)).to eq("gar_v20260116")
    end

    it "не удаляет текущую схему при импорте той же версии (ошибка 7)" do
      importer.import_full_base(zip_path)
      Gar.configuration.database_schema = import_schema

      expect { importer.import_full_base(zip_path) }.to raise_error(Gar::ImportError, /текущая/)
      expect(table_count(import_schema, "houses")).to eq(10)
    end

    it "не использует остатки распаковки прерванного импорта 1.x (ошибка 4)" do
      entry = Zip::File.open(zip_path) { |zip| zip.entries.map(&:name).find { |name| name.start_with?("43/AS_HOUSES_2") } }
      leftover = File.join(archive_dir, File.basename(zip_path, ".zip"), entry)
      FileUtils.mkdir_p(File.dirname(leftover))
      File.write(leftover, %(<?xml version="1.0" encoding="utf-8"?><HOUSES>))

      importer.import_full_base(zip_path)

      expect(table_count(import_schema, "houses")).to eq(10)
    end
  end

  describe "построение путей" do
    let(:schema) { import_with_paths }

    it "строит административные и муниципальные пути адресных объектов" do
      adm = column_by_object(schema, "address_objects", "full_adm_path")
      mun = column_by_object(schema, "address_objects", "full_mun_path")

      expect(adm[4_300_010]).to eq("Кировская обл, Киров г, Ленина ул")
      expect(mun[4_300_010]).to eq("Кировская обл, город Киров г.о., Киров г, Ленина ул")
      expect(adm[4_300_002]).to be_nil # городской округ есть только в муниципальной иерархии
    end

    it "строит пути домов с коротким типом дома, без корпуса и строения" do
      adm = column_by_object(schema, "houses", "full_adm_path")

      expect(adm[4_300_101]).to eq("Кировская обл, Киров г, Ленина ул, д. 10")
      expect(adm[4_300_103]).to eq("Кировская обл, Киров г, Ленина ул, д. 10/2")
      expect(adm[4_300_104]).to eq("Кировская обл, Киров г, Ленина ул, д. 12") # корпус 2 теряется (Т8, этап 4)
    end

    it "без муниципальной иерархии строит только административные пути" do
      Gar.configuration.hierarchies = [:adm]
      schema = import_with_paths

      expect(column_by_object(schema, "houses", "full_adm_path")[4_300_101]).to eq("Кировская обл, Киров г, Ленина ул, д. 10")
      expect(column_by_object(schema, "houses", "full_mun_path").values.uniq).to eq([nil])
    end

    it "использует текущее название улицы в путях её домов" do
      expect(column_by_object(schema, "houses", "full_adm_path")[4_300_201]).to eq("Кировская обл, Киров г, Воровского ул, д. 5")
    end
  end

  describe "поиск" do
    let(:search) { Gar::Search.new(db_connection) }

    before { Gar.configuration.database_schema = import_with_paths }

    it "находит улицы по названию во всех субъектах" do
      expect(search.search_address_objects("Ленина").map(&:object_guid))
        .to contain_exactly(guid(4_300_010), guid(1_100_010))
    end

    it "сначала отдаёт совпадения по названию, затем по пути, с общей пагинацией" do
      found = search.search_address_objects("Киров")

      expect(found.first(2).map(&:name)).to contain_exactly("Киров", "город Киров")
      expect(found.drop(2).map(&:name)).to contain_exactly("Ленина", "Воровского")
      expect(search.search_address_objects("Киров", limit: 2, offset: 1)).to eq(found[1, 2])
    end

    it "находит дома по улице и номеру без границы субъекта (Т6)" do
      expect(search.search_houses("Ленина 10").map(&:object_guid))
        .to contain_exactly(guid(4_300_101), guid(1_100_101))
    end

    it "в режиме автодополнения ищет номер по префиксу и пропускает неактивные дома" do
      expect(search.search_houses("Ленина 1", autocomplete: true).map(&:gar_id))
        .to contain_exactly(1_100_101, 4_300_101, 4_300_102, 4_300_103, 4_300_104, 4_300_105, 4_300_106)
    end

    it "отдаёт регионы и прямых потомков по иерархии" do
      expect(search.find_address_objects.map(&:name)).to contain_exactly("Кировская", "Коми", "Москва")
      expect(search.find_address_objects(parent_guid: guid(4_300_003)).map(&:name)).to eq(["Воровского", "Ленина"])
    end

    it "отдаёт активные дома улицы по номеру" do
      expect(search.find_houses(guid(4_300_010)).map(&:house_num)).to eq(["10", "10/2", "10а", "12", "12", "14"])
    end

    it "находит объекты по GUID с текущим названием" do
      expect(search.find_address_object_by_guid(guid(4_300_011)).name).to eq("Воровского")
      expect(search.find_house_by_guid(guid(4_300_104))).to have_attributes(house_num: "12", house_type: "д.")
    end

    it "фильтрует потомков по списку уровней (ошибка 19)" do
      expect(search.find_address_objects(parent_guid: guid(4_300_001), level: [5, 8]).map(&:name)).to eq(["Киров"])
    end
  end

  describe "переключение схем" do
    let(:current_schema) { isolated_schema("gar_current") }
    let(:backup_schema)  { "gar_backup_v20260116" }

    before do
      register_schema_for_cleanup(backup_schema)
      Gar.configuration.database_schema = current_schema
    end

    it "делает импортированную схему текущей" do
      importer.switch_to_imported_schema(importer.import_full_base(zip_path))

      expect(schema_exists?(current_schema)).to be(true)
      expect(schema_exists?(import_schema)).to be(false)
      expect(table_count(current_schema, "houses")).to eq(10)
    end

    it "сохраняет прежнюю текущую схему как резервную с её версией" do
      importer.switch_to_imported_schema(importer.import_full_base(zip_path))
      importer.switch_to_imported_schema(importer.import_full_base(zip_path))

      expect(schema_exists?(backup_schema)).to be(true)
      expect(schema_exists?(current_schema)).to be(true)
    end
  end
end
