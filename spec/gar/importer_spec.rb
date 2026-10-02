# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Gar::Importer, :db do
  let(:archive_dir) { Dir.mktmpdir("gar_importer") }
  let(:builder)     { GarSampleArchive.build }
  let(:zip_path)    { builder.write(archive_dir) }
  let(:importer)    { described_class.new(db_connection) }
  let(:schema)      { isolated_schema("gar_import") }

  after { FileUtils.rm_rf(archive_dir) }

  def import(**)
    importer.import_full_base(zip_path, schema:, **)
  end

  def tables_in(name)
    db_connection.exec_params("SELECT tablename FROM pg_tables WHERE schemaname = $1", [name]).column_values(0).map(&:to_sym)
  end

  def values(table, column = "id")
    db_connection.exec("SELECT DISTINCT #{column} FROM #{schema}.#{table} ORDER BY 1").column_values(0)
  end

  describe "#import_full_base: состав данных" do
    let(:dictionaries) { Gar::Schema::DICTIONARIES.map(&:name) }

    it "по умолчанию загружает справочники и минимальный набор таблиц субъекта" do
      expect(import).to eq(schema)

      expect(tables_in(schema)).to match_array(dictionaries + Gar::Configuration::MINIMAL_TABLES + [:database_version])
    end

    it "набором :extended добавляет участки, помещения, реестр GUID и прежние названия улиц" do
      Gar.configuration.preset = :extended

      import

      expect(tables_in(schema)).to include(:steads, :stead_params, :apartments, :rooms, :reestr_objects, :addr_obj_division)
      expect(values("address_objects", "name")).to include("Старая")
      expect(table_count(schema, "steads")).to eq(1)
      expect(table_count(schema, "stead_params")).to eq(0) # кадастровый номер (8) не входит в типы набора
    end

    it "набором :full загружает все таблицы, все типы параметров и историю записей" do
      Gar.configuration.preset = :full

      import

      expect(tables_in(schema)).to match_array(Gar::Schema::TABLES.keys + [:database_version])
      expect(table_count(schema, "stead_params")).to eq(1)
      expect(values("addr_obj_params")).to eq(["1", "2", "3"])
      expect(table_count(schema, "change_history")).to eq(1)
    end

    it "дополняет набор таблицами из config.tables" do
      Gar.configuration.tables += [:steads]

      import

      expect(tables_in(schema)).to include(:steads).and exclude(:apartments)
    end

    it "загружает только иерархии из config.hierarchies" do
      Gar.configuration.hierarchies = [:mun]

      import

      expect(tables_in(schema)).to include(:mun_hierarchy).and exclude(:adm_hierarchy)
    end

    it "с keep_history хранит неактуальные записи" do
      Gar.configuration.keep_history = true

      import

      expect(table_count(schema, "address_objects")).to eq(12)
      expect(values("addr_obj_params")).to eq(["1", "2", "3"])
    end

    it "отбирает параметры по config.param_types" do
      Gar.configuration.param_types = [7]

      import

      expect(values("house_params", "value")).to eq(["33701000001"])
      expect(table_count(schema, "addr_obj_params")).to eq(0)
    end

    it "с region_codes загружает только выбранные субъекты, а справочники — всегда" do
      import(region_codes: ["43"])

      expect(values("houses", "region_code")).to eq(["43"])
      expect(values("adm_hierarchy", "region_code")).to eq(["43"])
      expect(table_count(schema, "house_types")).to eq(2)
    end

    it "загружает таблицы и в параллельных потоках" do
      Gar.configuration.parallel_import          = true
      Gar.configuration.parallel_import_strategy = :threads

      import

      expect(["address_objects", "houses", "adm_hierarchy", "house_params"].map { table_count(schema, _1) }).to eq([11, 10, 19, 3])
    end
  end

  describe "#import_full_base: после загрузки" do
    it "строит первичные ключи и индексы по описанию схемы и собирает статистику" do
      import

      indexes = db_connection.exec_params("SELECT indexname FROM pg_indexes WHERE schemaname = $1 AND tablename = 'houses'",
                                          [schema]).column_values(0)
      analyzed = db_connection.exec_params("SELECT DISTINCT tablename FROM pg_stats WHERE schemaname = $1", [schema]).column_values(0)

      expect(indexes).to contain_exactly("houses_pkey", "idx_houses_object_id", "idx_houses_object_guid")
      expect(analyzed).to include("houses", "address_objects", "house_params")
    end

    it "сообщает о прогрессе в байтах XML от нуля до полного объёма" do
      calls = []
      total = Gar::Archive.new(zip_path).jobs(Gar.configuration.import_tables).sum(&:size)

      import(on_progress: ->(done, all, stage) { calls << [done, all, stage] })

      expect(calls.first).to eq([0, total, :import])
      expect(calls.last).to eq([total, total, :import])
      expect(calls.map(&:first)).to eq(calls.map(&:first).sort)
    end
  end

  describe "#import_full_base: ошибки" do
    it "без version.txt бросает ImportError и не создаёт схему" do
      zip = builder.write(archive_dir, name: "broken.zip", version_txt: nil)

      expect { importer.import_full_base(zip, schema:) }.to raise_error(Gar::ImportError, /нет version.txt/)
      expect(schema_exists?(schema)).to be(false)
    end

    it "пересоздаёт схему, оставшуюся от прерванного импорта" do
      db_connection.exec("CREATE SCHEMA #{schema}; CREATE TABLE #{schema}.houses (id int); INSERT INTO #{schema}.houses VALUES (1)")

      import

      expect(table_count(schema, "houses")).to eq(10)
    end

    it "на повреждённом файле бросает ImportError с именем файла" do
      builder.file("43/AS_HOUSES_20260115_broken.XML", %(<?xml version="1.0" encoding="utf-8"?><HOUSES><HOUSE ID="1"))

      expect { import }.to raise_error(Gar::ImportError, %r{43/AS_HOUSES_20260115_broken.XML: Ошибка разбора XML})
    end

    it "передаёт ошибку из воркер-процесса" do
      skip "fork недоступен" unless Process.respond_to?(:fork)
      Gar.configuration.parallel_import          = true
      Gar.configuration.parallel_import_strategy = :processes
      builder.file("43/AS_HOUSES_20260115_broken.XML", "<HOUSES><HOUSE")

      expect { import }.to raise_error(Gar::ImportError, %r{43/AS_HOUSES_20260115_broken.XML})
      expect(db_connection.exec("SELECT 1").getvalue(0, 0)).to eq("1")
    end
  end

  describe "#switch_to_imported_schema" do
    let(:current) { isolated_schema("gar_current") }

    before { Gar.configuration.database_schema = current }

    it "делает схему текущей, а прежнюю текущую сохраняет как резервную с её версией" do
      backup = register_schema_for_cleanup("gar_backup_v20260116")
      importer.switch_to_imported_schema(import)
      importer.switch_to_imported_schema(importer.import_full_base(zip_path, schema: isolated_schema("gar_import")))

      expect(table_count(current, "houses")).to eq(10)
      expect(table_count(backup, "houses")).to eq(10)
      expect(schema_exists?(schema)).to be(false)
    end

    it "резервную копию схемы без database_version называет по времени" do
      db_connection.exec("CREATE SCHEMA #{current}")
      before = db_connection.exec("SELECT nspname FROM pg_namespace WHERE nspname LIKE 'gar\\_backup\\_2%'").column_values(0)

      importer.switch_to_imported_schema(import)

      backups = db_connection.exec("SELECT nspname FROM pg_namespace WHERE nspname LIKE 'gar\\_backup\\_2%'").column_values(0) - before
      backups.each { register_schema_for_cleanup(_1) }
      expect(backups).to contain_exactly(match(/\Agar_backup_\d{8}_\d{6}\z/))
    end

    it "отвергает пустое имя и несуществующую схему, текущую оставляет как есть" do
      expect { importer.switch_to_imported_schema("") }.to raise_error(ArgumentError, /пустым/)
      expect { importer.switch_to_imported_schema("gar_missing") }.to raise_error(ArgumentError, /не существует/)

      db_connection.exec("CREATE SCHEMA #{current}")
      expect { importer.switch_to_imported_schema(current) }.not_to(change { schema_exists?(current) })
    end
  end

  describe "#find_latest_full_base_zip" do
    it "возвращает самый свежий zip в каталоге или nil" do
      old_zip = File.join(archive_dir, "gar_xml_v1.zip").tap { FileUtils.touch(_1, mtime: Time.now - 60) }
      new_zip = File.join(archive_dir, "gar_xml_v2.zip").tap { FileUtils.touch(_1) }

      expect(importer.find_latest_full_base_zip(directory: archive_dir)).to eq(new_zip)
      expect(importer.find_latest_full_base_zip(directory: File.join(archive_dir, "missing"))).to be_nil
      FileUtils.rm([old_zip, new_zip])
      expect(importer.find_latest_full_base_zip(directory: archive_dir)).to be_nil
    end

    it "по умолчанию ищет в config.full_base_dir" do
      Gar.configuration.full_base_dir = archive_dir
      zip = File.join(archive_dir, "gar_xml_v1.zip").tap { FileUtils.touch(_1) }

      expect(importer.find_latest_full_base_zip).to eq(zip)
    end
  end
end
