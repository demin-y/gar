# frozen_string_literal: true

# rubocop:disable RSpec/LeakyConstantDeclaration
RSpec.describe Gar::Importer do
  let(:db_conn) { instance_double(PG::Connection) }
  let(:importer) { described_class.new(db_conn) }
  let(:db) { importer.instance_variable_get(:@db) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }

  before do
    allow(db_conn).to receive(:exec)
    allow(db_conn).to receive(:exec_params)
    allow(db_conn).to receive(:quote_ident) { |name| "\"#{name}\"" }
    allow(db_conn).to receive_messages(status: PG::CONNECTION_OK, finished?: false, backend_pid: 12_345)
    allow(Gar).to receive(:logger).and_return(logger)
  end

  # ============================================================================
  # Инициализация
  # ============================================================================

  describe "#initialize" do
    context "без db_conn" do
      let(:default_conn) { instance_double(PG::Connection, backend_pid: 1) }

      before do
        allow(Gar::Database).to receive(:create_connection).and_return(default_conn)
      end

      it "использует Database.create_connection по умолчанию" do
        new_importer = described_class.new
        expect(new_importer.db_conn).to eq(default_conn)
      end
    end

    context "с db_conn" do
      it "использует переданное подключение" do
        custom_conn = instance_double(PG::Connection, status: PG::CONNECTION_OK, backend_pid: 2)
        new_importer = described_class.new(custom_conn)
        expect(new_importer.db_conn).to eq(custom_conn)
      end
    end
  end

  # ============================================================================
  # Операции со схемой
  # ============================================================================

  describe "#create_schema" do
    it "выполняет CREATE SCHEMA" do
      importer.create_schema("test_schema")

      expect(db_conn).to have_received(:exec).with('CREATE SCHEMA "test_schema"')
    end

    it "не выполняет SQL для nil schema_name" do
      importer.create_schema(nil)

      expect(db_conn).not_to have_received(:exec)
    end

    context "когда возникает ошибка БД" do
      before do
        allow(db_conn).to receive(:exec).and_raise(PG::Error, "Connection error")
      end

      it "пробрасывает исключение" do
        expect { importer.create_schema("test") }.to raise_error(PG::Error)
      end
    end
  end

  describe "#drop_schema" do
    it "выполняет DROP SCHEMA IF EXISTS CASCADE" do
      importer.drop_schema("test_schema")

      expect(db_conn).to have_received(:exec).with('DROP SCHEMA IF EXISTS "test_schema" CASCADE')
    end

    it "не выполняет SQL для nil schema_name" do
      importer.drop_schema(nil)

      expect(db_conn).not_to have_received(:exec)
    end

    context "когда возникает ошибка БД" do
      before do
        allow(db_conn).to receive(:exec).and_raise(PG::Error, "Connection error")
      end

      it "не пробрасывает исключение (silent fail)" do
        expect { importer.drop_schema("test") }.not_to raise_error
      end
    end
  end

  # ============================================================================
  # Создание таблиц
  # ============================================================================

  describe "#create_tables" do
    before do
      mock_module =
        Module.new do
          self::SCHEMA = "CREATE TABLE IF NOT EXISTS %s (id INTEGER)"
        end
      stub_const("MockTableModule", mock_module)
      allow(Gar.configuration).to receive(:import_entities).and_return([:address_objects])
      allow(Gar::Entities).to receive(:get_table_module).with(:address_objects).and_return(MockTableModule)
    end

    it "создаёт таблицы для всех import_entities" do
      importer.create_tables

      expect(db_conn).to have_received(:exec).with("CREATE TABLE IF NOT EXISTS address_objects (id INTEGER)")
    end

    it "добавляет префикс схемы при передаче schema_name" do
      importer.create_tables("my_schema")

      expect(db_conn).to have_received(:exec).with("CREATE TABLE IF NOT EXISTS my_schema.address_objects (id INTEGER)")
    end

    it "пропускает сущности без модуля" do
      allow(Gar::Entities).to receive(:get_table_module).and_return(nil)

      importer.create_tables

      expect(db_conn).not_to have_received(:exec)
    end

    context "когда возникает ошибка создания таблицы" do
      before do
        allow(db_conn).to receive(:exec).and_raise(PG::Error, "Syntax error")
      end

      it "пробрасывает исключение" do
        expect { importer.create_tables }.to raise_error(PG::Error)
      end
    end
  end

  # ============================================================================
  # Переключение схемы
  # ============================================================================

  describe "#switch_to_imported_schema" do
    let(:current_schema) { "gar" }
    let(:new_schema) { "gar_v20241201" }

    before do
      allow(Gar.configuration).to receive(:database_schema).and_return(current_schema)
    end

    it "выбрасывает ошибку для пустого schema_name" do
      expect { importer.switch_to_imported_schema("") }
        .to raise_error(ArgumentError, /не может быть пустым/)
    end

    context "когда схема не существует" do
      before do
        allow(db_conn).to receive(:exec_params).and_return(instance_double(PG::Result, any?: false))
      end

      it "выбрасывает ошибку" do
        expect { importer.switch_to_imported_schema(new_schema) }
          .to raise_error(ArgumentError, /не существует/)
      end
    end

    context "когда new_schema совпадает с current_schema" do
      before do
        allow(db_conn).to receive(:exec_params).and_return(instance_double(PG::Result, any?: true))
      end

      it "не переименовывает схему" do
        importer.switch_to_imported_schema(current_schema)

        expect(db_conn).not_to have_received(:exec)
      end
    end

    context "когда текущая схема существует" do
      let(:version_result) { instance_double(PG::Result, ntuples: 1) }

      before do
        allow(db_conn).to receive(:exec_params).and_return(instance_double(PG::Result, any?: true))
        allow(version_result).to receive(:getvalue).with(0, 0).and_return("20241101")
        allow(db_conn).to receive(:exec).with(/SELECT.*FROM.*database_version/).and_return(version_result)
      end

      it "переименовывает текущую схему в backup" do
        importer.switch_to_imported_schema(new_schema)

        expect(db_conn).to have_received(:exec).with(/ALTER SCHEMA "gar" RENAME TO "gar_backup_v20241101"/)
      end

      it "переименовывает новую схему в текущую" do
        importer.switch_to_imported_schema(new_schema)

        expect(db_conn).to have_received(:exec).with(/ALTER SCHEMA.*RENAME TO/).at_least(:twice)
      end
    end

    context "когда текущая схема не существует" do
      before do
        call_count = 0
        allow(db_conn).to receive(:exec_params) do
          call_count += 1
          instance_double(PG::Result, any?: call_count == 1)
        end
      end

      it "пропускает backup и переименовывает новую схему" do
        importer.switch_to_imported_schema(new_schema)

        expect(db_conn).to have_received(:exec).with('ALTER SCHEMA "gar_v20241201" RENAME TO "gar"')
      end
    end
  end

  # ============================================================================
  # Импорт полной базы
  # ============================================================================

  describe "#import_full_base" do
    let(:zip_path) { "/tmp/gar_full_v20241201.zip" }

    before do
      allow(importer).to receive(:extract_version_from_archive).and_return(20_241_201)
      allow(importer).to receive(:drop_schema)
      allow(importer).to receive(:create_schema)
      allow(importer).to receive(:create_tables)
      allow(importer).to receive(:import_tables)
      allow(importer).to receive(:save_version_info)
    end

    it "извлекает версию из имени архива" do
      importer.import_full_base(zip_path)

      expect(importer).to have_received(:extract_version_from_archive).with(zip_path)
    end

    it "создаёт схему с версией в имени" do
      importer.import_full_base(zip_path)

      expect(importer).to have_received(:create_schema).with("gar_v20241201")
    end

    it "вызывает методы в правильном порядке" do
      importer.import_full_base(zip_path)

      expect(importer).to have_received(:extract_version_from_archive).ordered
      expect(importer).to have_received(:drop_schema).ordered
      expect(importer).to have_received(:create_schema).ordered
      expect(importer).to have_received(:create_tables).ordered
      expect(importer).to have_received(:save_version_info).ordered
      expect(importer).to have_received(:import_tables).ordered
    end

    it "возвращает имя созданной схемы" do
      result = importer.import_full_base(zip_path)

      expect(result).to eq("gar_v20241201")
    end

    context "когда возникает ошибка импорта" do
      before do
        allow(importer).to receive(:import_tables).and_raise(StandardError, "Import failed")
      end

      it "пробрасывает исключение" do
        expect { importer.import_full_base(zip_path) }.to raise_error(StandardError, "Import failed")
      end
    end
  end

  # rubocop:disable RSpec/NestedGroups
  describe "#find_latest_full_base_zip" do
    let(:test_dir) { "/tmp/test_gar_full_base_#{rand(100_000)}" }

    after do
      FileUtils.rm_rf(test_dir)
    end

    context "когда директория не существует" do
      it "возвращает nil" do
        result = importer.find_latest_full_base_zip(directory: "/nonexistent/path/#{rand(100_000)}")
        expect(result).to be_nil
      end
    end

    context "когда директория существует" do
      before do
        FileUtils.mkdir_p(test_dir)
      end

      context "когда нет ZIP файлов" do
        it "возвращает nil" do
          result = importer.find_latest_full_base_zip(directory: test_dir)
          expect(result).to be_nil
        end
      end

      context "когда есть один ZIP файл" do
        let(:zip_path) { File.join(test_dir, "gar_full_v20241201.zip") }

        before do
          FileUtils.touch(zip_path)
        end

        it "возвращает путь к этому файлу" do
          result = importer.find_latest_full_base_zip(directory: test_dir)
          expect(result).to eq(zip_path)
        end
      end

      context "когда есть несколько ZIP файлов" do
        let(:old_zip) { File.join(test_dir, "gar_full_v20241101.zip") }
        let(:new_zip) { File.join(test_dir, "gar_full_v20241201.zip") }

        before do
          FileUtils.touch(old_zip)
          sleep 0.01 # Гарантировать разный mtime
          FileUtils.touch(new_zip)
        end

        it "возвращает самый свежий по mtime" do
          result = importer.find_latest_full_base_zip(directory: test_dir)
          expect(result).to eq(new_zip)
          expect(File.mtime(result)).to be > File.mtime(old_zip)
        end
      end
    end

    context "без параметра directory" do
      before do
        allow(Gar.configuration).to receive(:full_base_dir).and_return(test_dir)
        FileUtils.mkdir_p(test_dir)
      end

      it "использует Gar.configuration.full_base_dir" do
        zip_path = File.join(test_dir, "gar_full_v20241201.zip")
        FileUtils.touch(zip_path)

        result = importer.find_latest_full_base_zip
        expect(result).to eq(zip_path)
      end
    end
  end
  # rubocop:enable RSpec/NestedGroups

  describe "#extract_version_from_archive" do
    it "извлекает версию из basename файла" do
      expect(importer.extract_version_from_archive("/path/to/gar_full_v20251106.zip")).to eq(20_251_106)
      expect(importer.extract_version_from_archive("/path/to/file_without_version.zip")).to eq(0)
      expect(importer.extract_version_from_archive("/path/v12345/gar_full_v20241201.zip")).to eq(20_241_201)
    end
  end

  # ============================================================================
  # Приватные методы
  # ============================================================================

  describe "#import_tables" do
    let(:zip_path) { "/tmp/test.zip" }
    let(:schema_name) { "gar_test" }
    let(:import_list) do
      [
        { table: :address_objects, key: "AS_ADDR_OBJ" },
        { table: :houses, key: "AS_HOUSES" }
      ]
    end

    before do
      allow(importer).to receive(:build_import_list).and_return(import_list)
      allow(importer).to receive(:import_table)
      allow(importer).to receive(:create_indexes)
      allow(importer).to receive(:cleanup_extracted_files)
    end

    it "импортирует все таблицы из build_import_list" do
      importer.send(:import_tables, zip_path, schema_name)

      expect(importer).to have_received(:import_table).exactly(2).times
      expect(importer).to have_received(:import_table).with(zip_path, schema_name, import_list[0], 1, 2)
      expect(importer).to have_received(:import_table).with(zip_path, schema_name, import_list[1], 2, 2)
    end

    it "создаёт индексы после импорта всех таблиц" do
      importer.send(:import_tables, zip_path, schema_name)

      expect(importer).to have_received(:create_indexes).with(schema_name).ordered
    end

    it "вызывает cleanup_extracted_files в ensure блоке" do
      importer.send(:import_tables, zip_path, schema_name)

      expect(importer).to have_received(:cleanup_extracted_files).with(zip_path)
    end

    it "очищает файлы даже при ошибке импорта" do
      allow(importer).to receive(:import_table).and_raise(StandardError, "Test error")

      expect { importer.send(:import_tables, zip_path, schema_name) }.to raise_error(StandardError, "Test error")
      expect(importer).to have_received(:cleanup_extracted_files).with(zip_path)
    end
  end

  describe "#import_table" do
    let(:zip_path) { "/tmp/test.zip" }
    let(:schema_name) { "gar_test" }
    let(:table_info) { { table: :address_objects, key: "AS_ADDR_OBJ" } }
    let(:xml_files) { ["/tmp/test/AS_ADDR_OBJ_1.xml", "/tmp/test/AS_ADDR_OBJ_2.xml"] }

    before do
      allow(importer).to receive(:extract_xml_for_table).and_return(xml_files)
      allow(importer).to receive(:import_xml_files_for_table)
      allow(logger).to receive(:info)
    end

    it "извлекает XML файлы через extract_xml_for_table" do
      importer.send(:import_table, zip_path, schema_name, table_info, 1, 5)

      expect(importer).to have_received(:extract_xml_for_table).with(zip_path, "AS_ADDR_OBJ")
    end

    it "импортирует файлы через import_xml_files_for_table" do
      importer.send(:import_table, zip_path, schema_name, table_info, 1, 5)

      expect(importer).to have_received(:import_xml_files_for_table).with(xml_files, :address_objects, schema_name)
    end

    it "выводит прогресс [N/Total]" do
      importer.send(:import_table, zip_path, schema_name, table_info, 3, 10)

      expect(logger).to have_received(:info).with(%r{\[3/10\]})
    end

    it "пропускает таблицу если файлы не найдены" do
      allow(importer).to receive(:extract_xml_for_table).and_return([])

      importer.send(:import_table, zip_path, schema_name, table_info, 1, 5)

      expect(importer).not_to have_received(:import_xml_files_for_table)
      expect(logger).to have_received(:info).with(/Импорт таблицы/)
    end

    it "пробрасывает ошибки импорта" do
      allow(importer).to receive(:import_xml_files_for_table).and_raise(StandardError, "Import error")

      expect { importer.send(:import_table, zip_path, schema_name, table_info, 1, 5) }.to raise_error(StandardError)
    end
  end

  describe "#import_xml_files_for_table" do
    let(:xml_files) { ["/tmp/file1.xml", "/tmp/file2.xml"] }
    let(:table_name) { :address_objects }
    let(:schema_name) { "gar_test" }

    before do
      allow(importer).to receive(:import_files_parallel)
      allow(importer).to receive(:import_files_sequential)
      allow(Gar.configuration).to receive(:parallel_import).and_return(false)
      allow(logger).to receive(:info)
    end

    it "использует параллельный импорт если parallel_import=true и файлов > 1" do
      allow(Gar.configuration).to receive(:parallel_import).and_return(true)

      importer.send(:import_xml_files_for_table, xml_files, table_name, schema_name)

      expect(importer).to have_received(:import_files_parallel).with(xml_files, table_name, schema_name)
      expect(importer).not_to have_received(:import_files_sequential)
    end

    it "использует последовательный импорт если parallel_import=false" do
      allow(Gar.configuration).to receive(:parallel_import).and_return(false)

      importer.send(:import_xml_files_for_table, xml_files, table_name, schema_name)

      expect(importer).not_to have_received(:import_files_parallel)
      expect(importer).to have_received(:import_files_sequential).with(xml_files, table_name, schema_name)
    end

    it "использует последовательный импорт если файл только один" do
      allow(Gar.configuration).to receive(:parallel_import).and_return(true)
      single_file = ["/tmp/file1.xml"]

      importer.send(:import_xml_files_for_table, single_file, table_name, schema_name)

      expect(importer).not_to have_received(:import_files_parallel)
      expect(importer).to have_received(:import_files_sequential).with(single_file, table_name, schema_name)
    end
  end

  describe "#import_single_file" do
    let(:xml_path) { "/tmp/test.xml" }
    let(:table_name) { :address_objects }
    let(:schema_name) { "gar_test" }
    let(:parser) { instance_double(Gar::XmlParser) }
    let(:parser_options) { { level: [1, 2], is_actual: true } }

    before do
      allow(Gar::XmlParser).to receive(:new).and_return(parser)
      allow(parser).to receive(:parse_and_yield)
      allow(importer).to receive(:build_parser_options).and_return(parser_options)
      allow(importer).to receive(:copy_batch_data)
    end

    it "создаёт XmlParser без параметров" do
      importer.send(:import_single_file, xml_path, table_name, schema_name, db)

      expect(Gar::XmlParser).to have_received(:new).with(no_args)
    end

    it "получает опции через build_parser_options" do
      importer.send(:import_single_file, xml_path, table_name, schema_name, db)

      expect(importer).to have_received(:build_parser_options).with(table_name)
    end

    it "передаёт batch в copy_batch_data" do
      test_batch = [{ id: 1, name: "Test" }]
      allow(parser).to receive(:parse_and_yield).and_yield(test_batch, [:id, :name])

      importer.send(:import_single_file, xml_path, table_name, schema_name, db)

      expect(importer).to have_received(:copy_batch_data).with(db, test_batch, [:id, :name], table_name, schema_name)
    end
  end

  describe "#create_indexes" do
    let(:schema_name) { "gar_test" }
    let(:indexes) do
      [
        "CREATE INDEX idx1 ON %s(column1)",
        "CREATE INDEX idx2 ON %s(column2)"
      ]
    end

    before do
      allow(importer).to receive(:collect_all_indexes).and_return(indexes)
      allow(importer).to receive(:create_indexes_parallel)
      allow(importer).to receive(:create_indexes_sequential)
      allow(logger).to receive(:info)
    end

    it "собирает все индексы через collect_all_indexes" do
      allow(importer).to receive(:parallel_import_enabled?).and_return(true)

      importer.send(:create_indexes, schema_name)

      expect(importer).to have_received(:collect_all_indexes).with(schema_name)
    end

    context "когда parallel_import включён и индексов больше одного" do
      it "использует create_indexes_sequential для создания индексов" do
        allow(importer).to receive(:parallel_import_enabled?).and_return(true)

        importer.send(:create_indexes, schema_name)

        expect(importer).to have_received(:create_indexes_sequential).with(indexes)
        expect(importer).not_to have_received(:create_indexes_parallel)
      end
    end

    context "когда parallel_import отключён" do
      it "использует create_indexes_sequential для создания индексов" do
        allow(importer).to receive(:parallel_import_enabled?).and_return(false)

        importer.send(:create_indexes, schema_name)

        expect(importer).to have_received(:create_indexes_sequential).with(indexes)
        expect(importer).not_to have_received(:create_indexes_parallel)
      end
    end

    context "когда только один индекс" do
      let(:indexes) { ["CREATE INDEX idx1 ON %s(column1)"] }

      it "использует create_indexes_sequential" do
        allow(importer).to receive(:parallel_import_enabled?).and_return(true)

        importer.send(:create_indexes, schema_name)

        expect(importer).to have_received(:create_indexes_sequential).with(indexes)
        expect(importer).not_to have_received(:create_indexes_parallel)
      end
    end

    it "пропускает если индексов нет" do
      allow(importer).to receive_messages(collect_all_indexes: [], parallel_import_enabled?: true)

      importer.send(:create_indexes, schema_name)

      expect(importer).not_to have_received(:create_indexes_parallel)
      expect(importer).not_to have_received(:create_indexes_sequential)
    end
  end

  describe "#create_indexes_parallel" do
    let(:indexes) do
      [
        "CREATE INDEX idx1 ON table1(column1)",
        "CREATE INDEX idx2 ON table2(column2)"
      ]
    end

    before do
      allow(importer).to receive(:execute_in_parallel)
    end

    it "вызывает execute_in_parallel для создания индексов" do
      importer.send(:create_indexes_parallel, indexes)

      expect(importer).to have_received(:execute_in_parallel).with(indexes)
    end
  end

  describe "#create_indexes_sequential" do
    let(:indexes) do
      [
        "CREATE INDEX idx1 ON table1(column1)",
        "CREATE INDEX idx2 ON table2(column2)"
      ]
    end

    before do
      allow(db_conn).to receive(:exec)
      allow(importer).to receive(:log_progress)
    end

    it "выполняет индексы последовательно через db_conn.exec" do
      importer.send(:create_indexes_sequential, indexes)

      expect(db_conn).to have_received(:exec).with(indexes[0]).ordered
      expect(db_conn).to have_received(:exec).with(indexes[1]).ordered
    end

    it "логирует прогресс для каждого индекса" do
      importer.send(:create_indexes_sequential, indexes)

      expect(importer).to have_received(:log_progress).with(1, 2).ordered
      expect(importer).to have_received(:log_progress).with(2, 2).ordered
    end
  end

  describe "#collect_all_indexes" do
    let(:schema_name) { "gar_test" }

    before do
      # Создаём модуль с константой INDEXES
      stub_const("TestAdmHierarchyModule", Module.new)
      TestAdmHierarchyModule.const_set(:INDEXES, [
                                         "CREATE INDEX idx_adm_hierarchy_object_id ON %s(object_id)",
                                         "CREATE INDEX idx_adm_hierarchy_parent_obj_id ON %s(parent_obj_id)"
                                       ])

      allow(Gar.configuration).to receive(:import_entities).and_return([:adm_hierarchy, :nonexistent_table])
      allow(Gar::Entities).to receive(:get_table_module).with(:adm_hierarchy).and_return(TestAdmHierarchyModule)
      allow(Gar::Entities).to receive(:get_table_module).with(:nonexistent_table).and_return(nil)
    end

    it "собирает SQL для всех индексов с подстановкой schema_name, пропуская таблицы без модуля" do
      result = importer.send(:collect_all_indexes, schema_name)

      expect(result).to be_an(Array)
      expect(result.size).to eq(2) # Только от adm_hierarchy, nonexistent_table пропущена
      expect(result[0]).to include("gar_test.adm_hierarchy")
      expect(result[1]).to include("gar_test.adm_hierarchy")
    end
  end

  describe "#execute_in_parallel" do
    let(:items) { (1..10).to_a }
    let(:workers_count) { 4 }
    let(:parallel_conn) { instance_double(PG::Connection, close: nil, finished?: false) }

    before do
      allow(Gar.configuration).to receive_messages(parallel_import_workers: workers_count, parallel_import_strategy: :threads)
      allow(Gar::Database).to receive(:create_connection).and_return(parallel_conn)
      allow(importer).to receive(:build_parallel_options).and_call_original
      allow(importer).to receive(:log_progress)
      allow(Parallel).to receive(:each)
    end

    it "вызывает build_parallel_options с workers_count и total" do
      importer.send(:execute_in_parallel, items) { |_handle, _item| } # rubocop:disable Lint/EmptyBlock

      expect(importer).to have_received(:build_parallel_options).with(workers_count, items.size)
    end

    it "передаёт items напрямую в Parallel.each" do
      importer.send(:execute_in_parallel, items) { |_handle, _item| } # rubocop:disable Lint/EmptyBlock

      expect(Parallel).to have_received(:each).with(items, anything)
    end
  end

  describe "#build_parallel_options" do
    let(:workers_count) { 4 }
    let(:total) { 100 }

    before do
      allow(importer).to receive(:log_progress).and_call_original
    end

    context "when strategy is :threads" do
      before { allow(Gar.configuration).to receive(:parallel_import_strategy).and_return(:threads) }

      it "возвращает Hash с in_threads и finish callback" do
        options = importer.send(:build_parallel_options, workers_count, total)

        expect(options).to be_a(Hash)
        expect(options[:in_threads]).to eq(workers_count)
        expect(options[:finish]).to be_a(Proc)
      end
    end

    context "when strategy is :processes" do
      before { allow(Gar.configuration).to receive(:parallel_import_strategy).and_return(:processes) }

      it "возвращает Hash с in_processes и finish callback" do
        options = importer.send(:build_parallel_options, workers_count, total)

        expect(options[:in_processes]).to eq(workers_count)
        expect(options[:finish]).to be_a(Proc)
      end
    end

    it "finish callback выводит прогресс только при достижении новых порогов" do
      allow(Gar.configuration).to receive(:parallel_import_strategy).and_return(:threads)
      options = importer.send(:build_parallel_options, workers_count, total)

      # Симулируем обработку items с переходом через пороги (при total=100)
      # Вызываем callback 25 раз для достижения 25%
      25.times { |i| options[:finish].call("item#{i + 1}", i, nil) }

      # Прогресс выводится только при достижении новых 10%-х порогов
      expect(logger).to have_received(:info).with(%r{Прогресс: 1/#{total}}).ordered   # 1% (первый item, 0-9% порог)
      expect(logger).to have_received(:info).with(%r{Прогресс: 10/#{total}}).ordered  # 10% (10-й item, 10-19% порог)
      expect(logger).to have_received(:info).with(%r{Прогресс: 20/#{total}}).ordered  # 20% (20-й item, 20-29% порог)
      expect(logger).to have_received(:info).with(/Прогресс:/).exactly(3).times
    end
  end

  describe "#split_into_chunks" do
    it "разбивает массив на num_chunks частей с балансировкой" do
      result = importer.send(:split_into_chunks, (1..10).to_a, 3)

      expect(result.size).to eq(3)
      expect(result.flatten).to eq((1..10).to_a)
      expect(result[0].size).to be >= 3
    end

    it "возвращает 1 чанк если num_chunks=1" do
      result = importer.send(:split_into_chunks, (1..10).to_a, 1)

      expect(result.size).to eq(1)
      expect(result[0]).to eq((1..10).to_a)
    end
  end

  describe "#extract_xml_for_table" do
    let(:zip_path) { "/tmp/test_gar.zip" }
    let(:table_key) { "AS_ADDR_OBJ" }
    let(:zip_file_mock) { instance_double(Zip::File) }

    it "создаёт директорию для извлечения" do
      allow(Zip::File).to receive(:open).and_yield(zip_file_mock)
      allow(zip_file_mock).to receive(:each)
      allow(FileUtils).to receive(:mkdir_p)

      importer.send(:extract_xml_for_table, zip_path, table_key)

      expect(FileUtils).to have_received(:mkdir_p).with("/tmp/test_gar")
    end
  end

  describe "#cleanup_extracted_files" do
    let(:zip_path) { "/tmp/test_gar.zip" }
    let(:extract_dir) { "/tmp/test_gar" }

    before do
      allow(Dir).to receive(:exist?).with(extract_dir).and_return(true)
      allow(FileUtils).to receive(:rm_rf).and_return(nil)
      allow(logger).to receive(:debug)
    end

    it "удаляет директорию с извлечёнными файлами" do
      importer.send(:cleanup_extracted_files, zip_path)

      expect(FileUtils).to have_received(:rm_rf).with(extract_dir)
    end

    it "не удаляет если директория не существует" do
      allow(Dir).to receive(:exist?).with(extract_dir).and_return(false)

      importer.send(:cleanup_extracted_files, zip_path)

      expect(FileUtils).not_to have_received(:rm_rf)
    end
  end

  describe "#import_files_parallel" do
    let(:xml_files) { ["/tmp/file1.xml", "/tmp/file2.xml"] }
    let(:table_name) { :address_objects }
    let(:schema_name) { "gar_test" }

    before do
      allow(importer).to receive(:execute_in_parallel)
    end

    it "вызывает execute_in_parallel с xml_files" do
      importer.send(:import_files_parallel, xml_files, table_name, schema_name)

      expect(importer).to have_received(:execute_in_parallel).with(xml_files)
    end
  end

  describe "#import_files_sequential" do
    let(:xml_files) { ["/tmp/file1.xml", "/tmp/file2.xml"] }
    let(:table_name) { :address_objects }
    let(:schema_name) { "gar_test" }

    before do
      allow(importer).to receive(:import_single_file)
      allow(importer).to receive(:log_progress)
    end

    it "импортирует файлы по очереди" do
      importer.send(:import_files_sequential, xml_files, table_name, schema_name)

      expect(importer).to have_received(:import_single_file).with(xml_files[0], table_name, schema_name, a_kind_of(Gar::Database))
      expect(importer).to have_received(:import_single_file).with(xml_files[1], table_name, schema_name, a_kind_of(Gar::Database))
    end

    it "выводит прогресс после каждого файла" do
      importer.send(:import_files_sequential, xml_files, table_name, schema_name)

      expect(importer).to have_received(:log_progress).exactly(2).times
    end
  end

  describe "#full_table_name" do
    it "возвращает полное имя таблицы с опциональной схемой" do
      expect(importer.send(:full_table_name, "address_objects", nil)).to eq("address_objects")
      expect(importer.send(:full_table_name, "address_objects", "gar_v20241201")).to eq("gar_v20241201.address_objects")
    end
  end

  describe "#backup_current_schema" do
    let(:current_schema) { "gar_test_current" }
    let(:version_id) { 20_241_201 }

    before do
      allow(importer).to receive(:schema_exists?).with(current_schema).and_return(true)
      allow(importer).to receive(:schema_exists?).with("gar_backup_v#{version_id}").and_return(false)
      allow(importer).to receive(:get_database_version).and_return(version_id)
      allow(importer).to receive(:rename_schema)
      allow(importer).to receive(:drop_schema)
      allow(logger).to receive(:info)
    end

    it "получает версию через get_database_version" do
      importer.send(:backup_current_schema, current_schema)

      expect(importer).to have_received(:get_database_version).with(current_schema)
    end

    it "переименовывает схему в gar_backup_v{version}" do
      importer.send(:backup_current_schema, current_schema)

      expect(importer).to have_received(:rename_schema).with(current_schema, "gar_backup_v#{version_id}")
    end

    it "использует timestamp если версия не найдена" do
      allow(importer).to receive(:get_database_version).and_return(nil)
      allow(importer).to receive(:schema_exists?).with(current_schema).and_return(true)
      allow(importer).to receive(:schema_exists?).with(/gar_backup_/).and_return(false)
      allow(Time).to receive(:now).and_return(Time.at(1_700_000_000))

      importer.send(:backup_current_schema, current_schema)

      expect(importer).to have_received(:rename_schema).with(current_schema, /gar_backup_\d+/)
    end

    it "не падает если схема не существует" do
      allow(importer).to receive(:schema_exists?).with(current_schema).and_return(false)

      expect { importer.send(:backup_current_schema, current_schema) }.not_to raise_error
      expect(importer).not_to have_received(:rename_schema)
    end
  end

  describe "#format_value_for_copy" do
    it "форматирует различные типы значений для PostgreSQL COPY" do
      # nil, boolean, числа
      expect(importer.send(:format_value_for_copy, nil)).to eq("\\N")
      expect(importer.send(:format_value_for_copy, true)).to eq("t")
      expect(importer.send(:format_value_for_copy, false)).to eq("f")
      expect(importer.send(:format_value_for_copy, 42)).to eq("42")
      expect(importer.send(:format_value_for_copy, 3.14)).to eq("3.14")

      # Date/Time
      expect(importer.send(:format_value_for_copy, Date.new(2024, 12, 1))).to eq("2024-12-01")
      expect(importer.send(:format_value_for_copy, Time.new(2024, 12, 1, 10, 30, 0))).to eq("2024-12-01 10:30:00")
    end

    it "экранирует специальные символы" do
      [
        ["hello\tworld", "hello\\tworld"],
        ["hello\nworld", "hello\\nworld"],
        ["hello\rworld", "hello\\rworld"],
        ["hello\\world", "hello\\\\world"]
      ].each do |input, expected|
        expect(importer.send(:format_value_for_copy, input)).to eq(expected)
      end
    end
  end

  describe "#build_import_list" do
    before do
      mock_module =
        Module.new do
          self::XML_KEY = "AS_ADDR_OBJ"
        end
      stub_const("MockXmlModule", mock_module)
      allow(Gar::Entities).to receive(:get_table_module).with(:address_objects).and_return(MockXmlModule)
    end

    it "возвращает список таблиц с ключами, пропуская таблицы без модуля" do
      allow(Gar.configuration).to receive(:import_entities).and_return([:address_objects])
      result = importer.send(:build_import_list)
      expect(result).to eq([{ table: :address_objects, key: "AS_ADDR_OBJ" }])

      # Пропускает таблицы без модуля
      allow(Gar.configuration).to receive(:import_entities).and_return([:address_objects, :unknown_table])
      allow(Gar::Entities).to receive(:get_table_module).with(:unknown_table).and_return(nil)
      result = importer.send(:build_import_list)
      expect(result).to eq([{ table: :address_objects, key: "AS_ADDR_OBJ" }])
    end
  end

  describe "#build_parser_options" do
    before do
      mock_module =
        Module.new do
          self::DEFAULT_PARSER_OPTIONS = { level: [1, 2, 3] }.freeze
        end
      stub_const("MockParserModule", mock_module)
      allow(Gar::Entities).to receive(:get_table_module).with(:address_objects).and_return(MockParserModule)
    end

    it "объединяет дефолтные опции с entity_options" do
      # Только дефолтные опции
      allow(Gar.configuration).to receive(:entity_options).and_return({})
      expect(importer.send(:build_parser_options, :address_objects)).to eq({ level: [1, 2, 3] })

      # Объединение с entity_options
      allow(Gar.configuration).to receive(:entity_options).and_return(address_objects: { is_active: true })
      expect(importer.send(:build_parser_options, :address_objects)).to eq({ level: [1, 2, 3], is_active: true })

      # entity_options переопределяют дефолтные
      allow(Gar.configuration).to receive(:entity_options).and_return(address_objects: { level: [5, 6] })
      expect(importer.send(:build_parser_options, :address_objects)).to eq({ level: [5, 6] })
    end

    it "обрабатывает edge cases" do
      # Неизвестная таблица
      allow(Gar::Entities).to receive(:get_table_module).with(:unknown).and_return(nil)
      expect(importer.send(:build_parser_options, :unknown)).to eq({})

      # Модуль без DEFAULT_PARSER_OPTIONS
      stub_const("MockEmptyModule", Module.new)
      allow(Gar::Entities).to receive(:get_table_module).with(:simple_table).and_return(MockEmptyModule)
      allow(Gar.configuration).to receive(:entity_options).and_return(simple_table: { filter: true })
      expect(importer.send(:build_parser_options, :simple_table)).to eq({ filter: true })
    end
  end

  describe "#copy_batch_data" do
    let(:batch) do
      [
        { id: 1, name: "Test", is_active: true },
        { id: 2, name: "Test2", is_active: false }
      ]
    end
    let(:headers) { [:id, :name, :is_active] }

    before do
      allow(db_conn).to receive(:quote_ident) { |s| "\"#{s}\"" }
      allow(db_conn).to receive(:copy_data).and_yield
      allow(db_conn).to receive(:put_copy_data)
    end

    it "не выполняет COPY для пустого батча" do
      importer.send(:copy_batch_data, db, [], headers, :address_objects)

      expect(db_conn).not_to have_received(:copy_data)
    end

    it "выполняет COPY с правильными заголовками" do
      importer.send(:copy_batch_data, db, batch, headers, :address_objects)

      expect(db_conn).to have_received(:copy_data)
        .with('COPY address_objects ("id","name","is_active") FROM STDIN')
    end

    it "добавляет схему к имени таблицы" do
      importer.send(:copy_batch_data, db, batch, headers, :address_objects, "my_schema")

      expect(db_conn).to have_received(:copy_data)
        .with('COPY my_schema.address_objects ("id","name","is_active") FROM STDIN')
    end

    it "форматирует данные через put_copy_data" do
      importer.send(:copy_batch_data, db, batch, headers, :address_objects)

      expect(db_conn).to have_received(:put_copy_data).with("1\tTest\tt\n")
      expect(db_conn).to have_received(:put_copy_data).with("2\tTest2\tf\n")
    end

    context "когда возникает ошибка COPY" do
      before do
        allow(db_conn).to receive(:copy_data).and_raise(PG::Error, "Copy failed")
        allow(db_conn).to receive(:put_copy_end)
      end

      it "пробрасывает исключение" do
        expect { importer.send(:copy_batch_data, db, batch, headers, :address_objects) }
          .to raise_error(PG::Error, "Copy failed")
      end
    end
  end

  describe "#save_version_info" do
    it "создаёт таблицу database_version" do
      importer.send(:save_version_info, "test_schema", 20_241_201)

      expect(db_conn).to have_received(:exec).with(/CREATE TABLE IF NOT EXISTS test_schema.database_version/)
    end

    it "вставляет версию в таблицу" do
      importer.send(:save_version_info, "test_schema", 20_241_201)

      expect(db_conn).to have_received(:exec_params).with(/INSERT INTO test_schema.database_version/, [20_241_201])
    end

    it "работает без schema_name" do
      importer.send(:save_version_info, nil, 20_241_201)

      expect(db_conn).to have_received(:exec).with(/CREATE TABLE IF NOT EXISTS database_version/)
      expect(db_conn).to have_received(:exec_params).with(/INSERT INTO database_version/, [20_241_201])
    end
  end

  describe "#schema_exists?" do
    it "проверяет существование схемы через параметризованный запрос" do
      # Схема существует
      allow(db_conn).to receive(:exec_params).and_return(instance_double(PG::Result, any?: true))
      expect(importer.send(:schema_exists?, "gar")).to be true

      # Схема не существует
      allow(db_conn).to receive(:exec_params).and_return(instance_double(PG::Result, any?: false))
      expect(importer.send(:schema_exists?, "nonexistent")).to be false

      # Использует параметризованный запрос
      importer.send(:schema_exists?, "test_schema")
      expect(db_conn).to have_received(:exec_params)
        .with(/SELECT.*FROM information_schema.schemata.*WHERE schema_name = \$1/, ["test_schema"])
    end
  end

  describe "#get_database_version" do
    it "возвращает версию из таблицы database_version или nil" do
      # Версия найдена
      result = instance_double(PG::Result, ntuples: 1)
      allow(result).to receive(:getvalue).with(0, 0).and_return("20241201")
      allow(db_conn).to receive(:exec)
        .with('SELECT version_id FROM "test_schema".database_version ORDER BY version_id DESC LIMIT 1')
        .and_return(result)
      expect(importer.send(:get_database_version, "test_schema")).to eq("20241201")

      # Версия не найдена
      allow(db_conn).to receive(:exec).and_return(instance_double(PG::Result, ntuples: 0))
      expect(importer.send(:get_database_version, "test_schema")).to be_nil
    end
  end

  # ============================================================================
  # Интеграционные тесты (с реальной БД)
  # ============================================================================

  # rubocop:disable RSpec/NestedGroups
  describe "интеграционные тесты", :integration do
    let(:real_db_conn) { IntegrationTestHelper.connection }
    let(:real_importer) { described_class.new(real_db_conn) }
    let(:test_schema) { "gar_test_#{Time.now.to_i}_#{rand(1000)}" }

    after do
      real_db_conn.exec("DROP SCHEMA IF EXISTS #{test_schema} CASCADE")
    rescue StandardError
      nil
    end

    describe "#create_schema + #drop_schema + #schema_exists?" do
      it "создаёт, проверяет и удаляет схему" do
        expect(real_importer.send(:schema_exists?, test_schema)).to be false

        real_importer.create_schema(test_schema)
        expect(real_importer.send(:schema_exists?, test_schema)).to be true

        real_importer.drop_schema(test_schema)
        expect(real_importer.send(:schema_exists?, test_schema)).to be false
      end
    end

    describe "#create_tables" do
      before do
        real_importer.create_schema(test_schema)
      end

      it "создаёт все таблицы в схеме" do
        real_importer.create_tables(test_schema)

        Gar.configuration.import_entities.each do |table_name|
          result = real_db_conn.exec_params(
            "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2",
            [test_schema, table_name.to_s]
          )
          expect(result.ntuples).to eq(1), "Таблица #{table_name} не создана"
        end
      end
    end

    describe "#copy_batch_data" do
      let(:batch) do
        [
          { id: 1, name: "Тест", is_active: true },
          { id: 2, name: "Тест2", is_active: false }
        ]
      end
      let(:copy_headers) { [:id, :name, :is_active] }

      before do
        real_importer.create_schema(test_schema)
        real_db_conn.exec("CREATE TABLE #{test_schema}.test_table (id INTEGER, name TEXT, is_active BOOLEAN)")
      end

      it "записывает данные через COPY" do
        real_db = Gar::Database.new(real_db_conn)
        real_importer.send(:copy_batch_data, real_db, batch, copy_headers, :test_table, test_schema)

        result = real_db_conn.exec("SELECT * FROM #{test_schema}.test_table ORDER BY id")
        expect(result.ntuples).to eq(2)
        expect(result[0]["id"]).to eq("1")
        expect(result[0]["name"]).to eq("Тест")
        expect(result[0]["is_active"]).to eq("t")
      end
    end

    describe "#switch_to_imported_schema" do
      let(:new_schema) { "#{test_schema}_new" }
      let(:current_schema_name) { test_schema }

      before do
        allow(Gar.configuration).to receive(:database_schema).and_return(current_schema_name)
        real_db_conn.exec("DROP SCHEMA IF EXISTS gar_backup_v20241101 CASCADE")
        real_importer.create_schema(new_schema)
        real_db_conn.exec("CREATE TABLE #{new_schema}.database_version (version_id BIGINT PRIMARY KEY)")
        real_db_conn.exec("INSERT INTO #{new_schema}.database_version (version_id) VALUES (20241201)")
      end

      after do
        real_db_conn.exec("DROP SCHEMA IF EXISTS #{new_schema} CASCADE")
        real_db_conn.exec("DROP SCHEMA IF EXISTS #{current_schema_name} CASCADE")
        real_db_conn.exec("DROP SCHEMA IF EXISTS gar_backup_v20241201 CASCADE")
        real_db_conn.exec("DROP SCHEMA IF EXISTS gar_backup_v20241101 CASCADE")
      rescue StandardError
        nil
      end

      it "переименовывает схему в текущую" do
        real_importer.switch_to_imported_schema(new_schema)

        expect(real_importer.send(:schema_exists?, current_schema_name)).to be true
        expect(real_importer.send(:schema_exists?, new_schema)).to be false
      end

      context "когда текущая схема существует" do
        before do
          real_importer.create_schema(current_schema_name)
          real_db_conn.exec("CREATE TABLE #{current_schema_name}.database_version (version_id BIGINT PRIMARY KEY)")
          real_db_conn.exec("INSERT INTO #{current_schema_name}.database_version (version_id) VALUES (20241101)")
        end

        it "создаёт backup старой схемы" do
          real_importer.switch_to_imported_schema(new_schema)

          expect(real_importer.send(:schema_exists?, "gar_backup_v20241101")).to be true
        end
      end
    end

    describe "#import_full_base", :slow do
      let(:version_id) { 20_251_106 }
      let(:zip_path) { GarArchiveHelper.create_test_archive(version_id: version_id) }
      let(:expected_schema) { "gar_v#{version_id}" }

      after do
        GarArchiveHelper.cleanup(zip_path)
        real_db_conn.exec("DROP SCHEMA IF EXISTS #{expected_schema} CASCADE")
      rescue StandardError
        nil
      end

      it "импортирует данные из тестового архива" do
        result_schema = real_importer.import_full_base(zip_path)

        expect(result_schema).to eq(expected_schema)
        expect(real_importer.send(:schema_exists?, expected_schema)).to be true

        result = real_db_conn.exec("SELECT COUNT(*) FROM #{expected_schema}.address_objects")
        expect(result[0]["count"].to_i).to be >= 1
      end
    end
  end
  # rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/NestedGroups
end
# rubocop:enable RSpec/LeakyConstantDeclaration
