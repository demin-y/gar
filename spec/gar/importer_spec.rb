# frozen_string_literal: true

RSpec.describe Gar::Importer, :db do
  include_context "с синтетическим архивом"

  let(:importer) { described_class.new(db_connection) }
  let(:schema)   { isolated_schema("gar_import") }

  def import(**)
    importer.import_full_base(zip_path, schema:, **)
  end

  def values(table, column = "id")
    db_connection.exec("SELECT DISTINCT #{column} FROM #{schema}.#{table} ORDER BY 1").column_values(0)
  end

  describe "#import_full_base: состав данных" do
    let(:dictionaries) { Gar::Schema::DICTIONARIES.map(&:name) }

    it "по умолчанию загружает справочники и минимальный набор таблиц субъекта" do
      expect(import).to eq(schema)

      expect(tables_in(schema)).to match_array(dictionaries + Gar::Configuration::MINIMAL_TABLES + [:gar_meta])
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

      expect(tables_in(schema)).to match_array(Gar::Schema::TABLES.keys + [:gar_meta])
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

    it "по config.region_codes не читает файлы других субъектов (Т5)" do
      # Файл субъекта 77 испорчен: импорт упал бы, если бы его прочитал
      archive_builder.file("77/AS_HOUSES_20260115_broken.XML", "<HOUSES><HOUSE")
      Gar.configuration.region_codes = [43, "11"]
      progress = []

      import(on_progress: ->(done, total, _stage) { progress << [done, total] })

      expect(values("houses", "region_code")).to eq(["11", "43"])
      expect(values("address_objects", "region_code")).to eq(["11", "43"])
      expect(table_count(schema, "address_object_types")).to eq(6)
      expected = Gar::Archive.new(zip_path).jobs(Gar.configuration.import_tables, region_codes: ["43", "11"]).sum(&:size)
      expect(progress.last).to eq([expected, expected])
    end

    it "отвергает код субъекта не из двух цифр" do
      expect { import(region_codes: ["4"]) }.to raise_error(Gar::ConfigurationError, /две цифры/)
      expect(schema_exists?(schema)).to be(false)
    end

    it "берёт только действующие параметры: не закрытые изменением и не истёкшие к дате выгрузки" do
      import

      expect(values("house_params", "value")).to eq(["33701000001", "610017"])
      Gar.configuration.keep_history = true
      import
      expect(values("house_params", "value")).to include("33401000000")
    end

    it "оставляет в иерархиях только загруженные объекты, если не отключён prune_hierarchy" do
      hierarchy_objects = -> { values("adm_hierarchy", "object_id").map(&:to_i) & [4_300_901, 4_300_902] }

      import
      expect(hierarchy_objects.call).to be_empty
      expect(table_count(schema, "adm_hierarchy")).to eq(19)

      Gar.configuration.preset = :extended
      import
      expect(hierarchy_objects.call).to eq([4_300_901, 4_300_902])

      Gar.configuration.preset          = :minimal
      Gar.configuration.prune_hierarchy = false
      import
      expect(hierarchy_objects.call).to eq([4_300_901, 4_300_902])
    end

    it "загружает таблицы и в параллельных потоках" do
      Gar.configuration.parallel_import          = true
      Gar.configuration.parallel_import_strategy = :threads

      import

      expect(["address_objects", "houses", "adm_hierarchy", "house_params"].map { table_count(schema, _1) }).to eq([11, 10, 19, 3])
    end
  end

  describe "#import_full_base: после загрузки" do
    it "записывает в gar_meta версию, настройки импорта и статус imported" do
      Gar.configuration.param_types = [5, 7]

      import(region_codes: ["43"])

      expect(Gar::Meta.read(db_connection, schema)).to have_attributes(
        version_id: 20_260_116, version_date: Date.new(2026, 1, 16), region_codes: ["43"], param_types: [5, 7],
        tables: Gar.configuration.import_tables.map(&:name), keep_history: [], prune_hierarchy: true,
        status: "imported", imported_at: be_within(60).of(Time.now), paths_built_at: nil, gem_version: Gar::VERSION
      )
    end

    it "оставляет схему в статусе importing, если импорт прервался" do
      archive_builder.file("43/AS_HOUSES_20260115_broken.XML", "<HOUSES><HOUSE")

      expect { import }.to raise_error(Gar::ImportError)
      expect(Gar::Meta.read(db_connection, schema)).to have_attributes(status: "importing", imported_at: nil)
    end

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
      zip = archive_builder.write(archive_dir, name: "broken.zip", version_txt: nil)

      expect { importer.import_full_base(zip, schema:) }.to raise_error(Gar::ImportError, /нет version.txt/)
      expect(schema_exists?(schema)).to be(false)
    end

    it "пересоздаёт схему, оставшуюся от прерванного импорта" do
      db_connection.exec("CREATE SCHEMA #{schema}; CREATE TABLE #{schema}.houses (id int); INSERT INTO #{schema}.houses VALUES (1)")

      import

      expect(table_count(schema, "houses")).to eq(10)
    end

    it "на повреждённом файле бросает ImportError с именем файла" do
      archive_builder.file("43/AS_HOUSES_20260115_broken.XML", %(<?xml version="1.0" encoding="utf-8"?><HOUSES><HOUSE ID="1"))

      expect { import }.to raise_error(Gar::ImportError, %r{43/AS_HOUSES_20260115_broken.XML: Ошибка разбора XML})
    end

    it "сообщает о гибели воркер-процесса и подсказывает, что делать при нехватке памяти" do
      Gar.configuration.parallel_import = true
      allow(Parallel).to receive(:each).and_raise(Parallel::DeadWorker)

      expect { import }.to raise_error(Gar::ImportError, /не хватило памяти.*parallel_import_workers/)
    end

    it "передаёт ошибку из воркер-процесса" do
      skip "fork недоступен" unless Process.respond_to?(:fork)
      Gar.configuration.parallel_import          = true
      Gar.configuration.parallel_import_strategy = :processes
      archive_builder.file("43/AS_HOUSES_20260115_broken.XML", "<HOUSES><HOUSE")

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

    it "резервную копию схемы без gar_meta называет по времени" do
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
