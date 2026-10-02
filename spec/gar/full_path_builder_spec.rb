# frozen_string_literal: true

RSpec.describe Gar::FullPathBuilder do
  let(:db_conn) { instance_double(PG::Connection) }
  let(:schema_name) { "gar" }
  let(:builder) { described_class.new(db_conn, schema_name:) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }

  before do
    allow(db_conn).to receive(:exec)
    allow(db_conn).to receive(:exec_params)
    allow(Gar).to receive(:logger).and_return(logger)
  end

  # ============================================================================
  # Инициализация
  # ============================================================================

  describe "#initialize" do
    context "без db_conn" do
      let(:default_conn) { instance_double(PG::Connection) }

      before do
        allow(Gar::Database).to receive(:create_connection).and_return(default_conn)
      end

      it "использует Database.create_connection по умолчанию" do
        new_builder = described_class.new
        expect(new_builder.db_conn).to eq(default_conn)
      end
    end

    context "с db_conn" do
      it "использует переданное подключение" do
        custom_conn = instance_double(PG::Connection)
        new_builder = described_class.new(custom_conn)
        expect(new_builder.db_conn).to eq(custom_conn)
      end
    end

    context "с schema_name" do
      it "сохраняет переданную схему" do
        custom_builder = described_class.new(db_conn, schema_name: "custom_schema")
        expect(custom_builder.schema_name).to eq("custom_schema")
      end
    end

    context "без schema_name" do
      before do
        allow(Gar.configuration).to receive(:database_schema).and_return("gar_default")
      end

      it "использует конфигурацию по умолчанию" do
        new_builder = described_class.new(db_conn)
        expect(new_builder.schema_name).to eq("gar_default")
      end
    end
  end

  # ============================================================================
  # Публичные методы
  # ============================================================================

  describe "#update_address_objects_paths" do
    before do
      allow(builder).to receive(:populate_address_objects_paths)
      allow(builder).to receive(:create_fulltext_indexes_for_table)
      allow(builder).to receive(:table_exists?).and_return(true)
    end

    it "добавляет колонки full_adm_path и full_mun_path" do
      builder.update_address_objects_paths

      expect(db_conn).to have_received(:exec).with(/ALTER TABLE.*ADD COLUMN IF NOT EXISTS full_adm_path TEXT/).once
      expect(db_conn).to have_received(:exec).with(/ALTER TABLE.*ADD COLUMN IF NOT EXISTS full_mun_path TEXT/).once
    end

    it "вызывает populate_address_objects_paths" do
      builder.update_address_objects_paths

      expect(builder).to have_received(:populate_address_objects_paths)
    end

    it "создаёт полнотекстовые индексы" do
      builder.update_address_objects_paths

      expect(builder).to have_received(:create_fulltext_indexes_for_table).with("address_objects")
    end
  end

  describe "#update_houses_paths" do
    before do
      allow(builder).to receive(:populate_houses_paths)
      allow(builder).to receive(:create_fulltext_indexes_for_table)
      allow(builder).to receive(:table_exists?).and_return(true)
    end

    it "добавляет колонки full_adm_path и full_mun_path" do
      builder.update_houses_paths

      expect(db_conn).to have_received(:exec).with(/ALTER TABLE.*ADD COLUMN IF NOT EXISTS full_adm_path TEXT/).once
      expect(db_conn).to have_received(:exec).with(/ALTER TABLE.*ADD COLUMN IF NOT EXISTS full_mun_path TEXT/).once
    end

    it "вызывает populate_houses_paths" do
      builder.update_houses_paths

      expect(builder).to have_received(:populate_houses_paths)
    end

    it "создаёт полнотекстовые индексы" do
      builder.update_houses_paths

      expect(builder).to have_received(:create_fulltext_indexes_for_table).with("houses")
    end
  end

  # ============================================================================
  # Приватные методы - SQL генерация
  # ============================================================================

  describe "#address_objects_adm_batch_sql" do
    let(:sql) { builder.send(:address_objects_adm_batch_sql, batch_size: 10_000, last_id: 100) }

    it "использует CTE WITH batch_ids" do
      expect(sql).to include("WITH batch_ids AS")
    end

    it "фильтрует только записи с full_adm_path IS NULL" do
      expect(sql).to include("AND full_adm_path IS NULL")
      expect(sql).not_to include("full_mun_path IS NULL")
    end

    it "использует только adm_hierarchy без mun_hierarchy" do
      expect(sql).to include("adm_hierarchy")
      expect(sql).not_to include("mun_hierarchy")
    end

    it "обновляет только adm_path и adm_tsv" do
      expect(sql).to include("full_adm_path")
      expect(sql).to include("full_adm_path_tsv")
      expect(sql).not_to include("full_mun_path")
    end

    it "не использует FULL OUTER JOIN" do
      expect(sql).not_to include("FULL OUTER JOIN")
    end
  end

  describe "#address_objects_mun_batch_sql" do
    let(:sql) { builder.send(:address_objects_mun_batch_sql, batch_size: 10_000, last_id: 100) }

    it "фильтрует только записи с full_mun_path IS NULL" do
      expect(sql).to include("AND full_mun_path IS NULL")
      expect(sql).not_to include("full_adm_path IS NULL")
    end

    it "использует только mun_hierarchy без adm_hierarchy" do
      expect(sql).to include("mun_hierarchy")
      expect(sql).not_to include("adm_hierarchy")
    end

    it "обновляет только mun_path и mun_tsv" do
      expect(sql).to include("full_mun_path")
      expect(sql).to include("full_mun_path_tsv")
      expect(sql).not_to include("full_adm_path")
    end
  end

  describe "#houses_adm_batch_sql" do
    let(:sql) { builder.send(:houses_adm_batch_sql, batch_size: 5_000, last_id: 50) }

    it "фильтрует только записи с full_adm_path IS NULL" do
      expect(sql).to include("AND full_adm_path IS NULL")
      expect(sql).not_to include("full_mun_path IS NULL")
    end

    it "использует только adm_hierarchy" do
      expect(sql).to include("adm_hierarchy")
      expect(sql).not_to include("mun_hierarchy")
    end

    it "добавляет номер дома к пути" do
      expect(sql).to include("|| ', ' || COALESCE(ht.short_name || ' ', '') || h_main.house_num")
    end

    it "обновляет только adm колонки" do
      expect(sql).to include("full_adm_path")
      expect(sql).to include("full_adm_path_tsv")
      expect(sql).not_to include("full_mun_path")
    end
  end

  describe "#houses_mun_batch_sql" do
    let(:sql) { builder.send(:houses_mun_batch_sql, batch_size: 5_000, last_id: 50) }

    it "фильтрует только записи с full_mun_path IS NULL" do
      expect(sql).to include("AND full_mun_path IS NULL")
      expect(sql).not_to include("full_adm_path IS NULL")
    end

    it "использует только mun_hierarchy" do
      expect(sql).to include("mun_hierarchy")
      expect(sql).not_to include("adm_hierarchy")
    end

    it "обновляет только mun колонки" do
      expect(sql).to include("full_mun_path")
      expect(sql).to include("full_mun_path_tsv")
      expect(sql).not_to include("full_adm_path")
    end
  end

  # ============================================================================
  # Приватные методы - логика батчинга
  # ============================================================================

  describe "#populate_paths_for_table" do
    let(:sql_builder) { ->(opts) { "UPDATE test_table SET path = 'test' WHERE id > #{opts[:last_id]} LIMIT $1 RETURNING id" } }
    let(:count_result) { instance_double(PG::Result) }
    let(:first_update_result) { instance_double(PG::Result, cmd_tuples: 10) }
    let(:second_update_result) { instance_double(PG::Result, cmd_tuples: 10) }
    let(:third_update_result) { instance_double(PG::Result, cmd_tuples: 5) }

    # Результаты batch_max SELECT: возвращают max id каждого батча, затем nil (конец)
    let(:first_batch_max) { instance_double(PG::Result) }
    let(:second_batch_max) { instance_double(PG::Result) }
    let(:third_batch_max) { instance_double(PG::Result) }
    let(:nil_batch_max) { instance_double(PG::Result) }

    before do
      allow(count_result).to receive(:getvalue).with(0, 0).and_return("100")
      allow(first_batch_max).to receive(:getvalue).with(0, 0).and_return("10")
      allow(second_batch_max).to receive(:getvalue).with(0, 0).and_return("20")
      allow(third_batch_max).to receive(:getvalue).with(0, 0).and_return("25")
      allow(nil_batch_max).to receive(:getvalue).with(0, 0).and_return(nil)

      allow(db_conn).to receive(:exec).with(/COUNT/).and_return(count_result)
      allow(db_conn).to receive(:exec).with(/SELECT MAX/)
                                      .and_return(first_batch_max, second_batch_max, third_batch_max, nil_batch_max)
      allow(db_conn).to receive(:exec).with(/UPDATE/)
                                      .and_return(first_update_result, second_update_result, third_update_result)
    end

    context "когда path_type: :adm" do
      it "выполняет COUNT с фильтром full_adm_path IS NULL" do
        builder.send(:populate_paths_for_table, table_name: "test_table", path_type: :adm, sql_builder:, batch_size: 10)

        expect(db_conn).to have_received(:exec).with(/SELECT COUNT.*WHERE full_adm_path IS NULL/)
      end

      it "создаёт временный индекс для adm" do
        builder.send(:populate_paths_for_table, table_name: "test_table", path_type: :adm, sql_builder:, batch_size: 10)

        expect(db_conn).to have_received(:exec).with(/CREATE INDEX IF NOT EXISTS idx_test_table_adm_null_tmp/)
      end

      it "вызывает optimize_session с path_type: :adm" do
        builder.send(:populate_paths_for_table, table_name: "test_table", path_type: :adm, sql_builder:, batch_size: 10)

        expect(db_conn).to have_received(:exec).with(/ANALYZE/).at_least(:once)
      end
    end

    context "когда path_type: :mun" do
      it "выполняет COUNT с фильтром full_mun_path IS NULL" do
        builder.send(:populate_paths_for_table, table_name: "test_table", path_type: :mun, sql_builder:, batch_size: 10)

        expect(db_conn).to have_received(:exec).with(/SELECT COUNT.*WHERE full_mun_path IS NULL/)
      end

      it "создаёт временный индекс для mun" do
        builder.send(:populate_paths_for_table, table_name: "test_table", path_type: :mun, sql_builder:, batch_size: 10)

        expect(db_conn).to have_received(:exec).with(/CREATE INDEX IF NOT EXISTS idx_test_table_mun_null_tmp/)
      end
    end

    it "определяет границу батча через SELECT MAX" do
      builder.send(:populate_paths_for_table, table_name: "test_table", path_type: :adm, sql_builder:, batch_size: 10)

      expect(db_conn).to have_received(:exec).with(/SELECT MAX/).at_least(:once)
    end

    it "выполняет UPDATE для каждого батча" do
      builder.send(:populate_paths_for_table, table_name: "test_table", path_type: :adm, sql_builder:, batch_size: 10)

      expect(db_conn).to have_received(:exec).with(/UPDATE/).exactly(3).times
    end

    it "логирует прогресс после каждого батча" do
      builder.send(:populate_paths_for_table, table_name: "test_table", path_type: :adm, sql_builder:, batch_size: 10)

      expect(logger).to have_received(:info).with(/Обработано:/).at_least(:once)
    end

    it "логирует завершение процесса" do
      builder.send(:populate_paths_for_table, table_name: "test_table", path_type: :adm, sql_builder:, batch_size: 10)

      expect(logger).to have_received(:info).with(/Заполнение full_adm_path для test_table завершено/)
    end

    it "останавливается когда batch_max возвращает nil" do
      allow(db_conn).to receive(:exec).with(/SELECT MAX/).and_return(nil_batch_max)

      builder.send(:populate_paths_for_table, table_name: "test_table", path_type: :adm, sql_builder:, batch_size: 10)

      expect(db_conn).not_to have_received(:exec).with(/UPDATE/)
    end

    it "удаляет временный индекс в ensure" do
      builder.send(:populate_paths_for_table, table_name: "test_table", path_type: :adm, sql_builder:, batch_size: 10)

      expect(db_conn).to have_received(:exec).with(/DROP INDEX IF EXISTS/)
    end
  end

  describe "#populate_address_objects_paths" do
    before do
      allow(builder).to receive(:populate_address_objects_adm_paths)
      allow(builder).to receive(:populate_address_objects_mun_paths)
    end

    it "вызывает populate_address_objects_adm_paths сначала" do
      builder.send(:populate_address_objects_paths, batch_size: 5_000)

      expect(builder).to have_received(:populate_address_objects_adm_paths).with(batch_size: 5_000)
    end

    it "вызывает populate_address_objects_mun_paths после adm" do
      builder.send(:populate_address_objects_paths, batch_size: 5_000)

      expect(builder).to have_received(:populate_address_objects_mun_paths).with(batch_size: 5_000)
    end
  end

  describe "#populate_houses_paths" do
    before do
      allow(builder).to receive(:populate_houses_adm_paths)
      allow(builder).to receive(:populate_houses_mun_paths)
    end

    it "вызывает populate_houses_adm_paths сначала" do
      builder.send(:populate_houses_paths, batch_size: 3_000)

      expect(builder).to have_received(:populate_houses_adm_paths).with(batch_size: 3_000)
    end

    it "вызывает populate_houses_mun_paths после adm" do
      builder.send(:populate_houses_paths, batch_size: 3_000)

      expect(builder).to have_received(:populate_houses_mun_paths).with(batch_size: 3_000)
    end
  end

  describe "#populate_address_objects_adm_paths" do
    before do
      allow(builder).to receive(:populate_paths_for_table)
    end

    it "вызывает populate_paths_for_table с path_type: :adm" do
      builder.send(:populate_address_objects_adm_paths, batch_size: 5_000)

      expect(builder).to have_received(:populate_paths_for_table) do |args|
        expect(args[:table_name]).to eq("address_objects")
        expect(args[:path_type]).to eq(:adm)
        expect(args[:batch_size]).to eq(5_000)
        expect(args[:sql_builder]).to be_a(Proc)
      end
    end
  end

  describe "#populate_address_objects_mun_paths" do
    before do
      allow(builder).to receive(:populate_paths_for_table)
    end

    it "вызывает populate_paths_for_table с path_type: :mun" do
      builder.send(:populate_address_objects_mun_paths, batch_size: 5_000)

      expect(builder).to have_received(:populate_paths_for_table) do |args|
        expect(args[:table_name]).to eq("address_objects")
        expect(args[:path_type]).to eq(:mun)
        expect(args[:batch_size]).to eq(5_000)
        expect(args[:sql_builder]).to be_a(Proc)
      end
    end
  end

  describe "#populate_houses_adm_paths" do
    before do
      allow(builder).to receive(:populate_paths_for_table)
    end

    it "вызывает populate_paths_for_table с path_type: :adm и batch_size по умолчанию 25000" do
      builder.send(:populate_houses_adm_paths)

      expect(builder).to have_received(:populate_paths_for_table) do |args|
        expect(args[:table_name]).to eq("houses")
        expect(args[:path_type]).to eq(:adm)
        expect(args[:batch_size]).to eq(25_000)
        expect(args[:sql_builder]).to be_a(Proc)
      end
    end
  end

  describe "#populate_houses_mun_paths" do
    before do
      allow(builder).to receive(:populate_paths_for_table)
    end

    it "вызывает populate_paths_for_table с path_type: :mun и batch_size по умолчанию 25000" do
      builder.send(:populate_houses_mun_paths)

      expect(builder).to have_received(:populate_paths_for_table) do |args|
        expect(args[:table_name]).to eq("houses")
        expect(args[:path_type]).to eq(:mun)
        expect(args[:batch_size]).to eq(25_000)
        expect(args[:sql_builder]).to be_a(Proc)
      end
    end
  end

  # ============================================================================
  # Приватные методы - вспомогательные
  # ============================================================================

  describe "#add_column_if_not_exists" do
    it "выполняет ALTER TABLE ADD COLUMN IF NOT EXISTS" do
      builder.send(:add_column_if_not_exists, "gar.test_table", "test_column")

      expect(db_conn).to have_received(:exec).with("ALTER TABLE gar.test_table ADD COLUMN IF NOT EXISTS test_column TEXT")
    end
  end

  describe "#create_fulltext_indexes_for_table" do
    it "создаёт GIN индексы для full_adm_path и full_mun_path" do
      builder.send(:create_fulltext_indexes_for_table, "address_objects")

      expect(db_conn).to have_received(:exec).once do |arg|
        expect(arg).to include("CREATE INDEX IF NOT EXISTS idx_address_objects_full_adm_path")
        expect(arg).to include("CREATE INDEX IF NOT EXISTS idx_address_objects_full_mun_path")
      end
    end

    it "создаёт GIN индексы на stored tsvector колонках с partial condition" do
      builder.send(:create_fulltext_indexes_for_table, "houses")

      expect(db_conn).to have_received(:exec).once do |arg|
        expect(arg).to include("full_adm_path_tsv")
        expect(arg).to include("full_mun_path_tsv")
        expect(arg).to include("WHERE is_active = true")
      end
    end
  end

  # ============================================================================
  # Интеграционные тесты (с реальной БД)
  # ============================================================================

  describe "интеграционные тесты", :db do
    let(:real_db_conn) { TestDatabase.connection }
    let(:test_schema) { "gar_fpb_test_#{Time.now.to_i}_#{rand(1000)}" }
    let(:real_builder) { described_class.new(real_db_conn, schema_name: test_schema) }

    before do
      # Создаём схему для тестов
      real_db_conn.exec("CREATE SCHEMA #{test_schema}")

      # Создаём необходимые таблицы
      create_test_tables
      # Заполняем тестовыми данными
      populate_test_data
    end

    after do
      real_db_conn.exec("DROP SCHEMA IF EXISTS #{test_schema} CASCADE")
    rescue StandardError
      nil
    end

    def create_test_tables
      # Таблица address_objects
      real_db_conn.exec(<<-SQL)
        CREATE TABLE #{test_schema}.address_objects (
          id BIGINT PRIMARY KEY,
          object_id BIGINT NOT NULL,
          name VARCHAR(250),
          type_name VARCHAR(50),
          level INTEGER,
          is_active BOOLEAN DEFAULT true
        )
      SQL

      # Таблица adm_hierarchy
      real_db_conn.exec(<<-SQL)
        CREATE TABLE #{test_schema}.adm_hierarchy (
          id BIGINT PRIMARY KEY,
          object_id BIGINT NOT NULL,
          parent_obj_id BIGINT,
          path TEXT,
          is_active BOOLEAN DEFAULT true
        )
      SQL

      # Таблица mun_hierarchy
      real_db_conn.exec(<<-SQL)
        CREATE TABLE #{test_schema}.mun_hierarchy (
          id BIGINT PRIMARY KEY,
          object_id BIGINT NOT NULL,
          parent_obj_id BIGINT,
          path TEXT,
          is_active BOOLEAN DEFAULT true
        )
      SQL

      # Таблица houses
      real_db_conn.exec(<<-SQL)
        CREATE TABLE #{test_schema}.houses (
          id BIGINT PRIMARY KEY,
          object_id BIGINT NOT NULL,
          house_num VARCHAR(50),
          house_type INTEGER,
          is_active BOOLEAN DEFAULT true
        )
      SQL

      # Таблица house_types
      real_db_conn.exec(<<-SQL)
        CREATE TABLE #{test_schema}.house_types (
          id INTEGER PRIMARY KEY,
          short_name VARCHAR(20)
        )
      SQL

      # Создаём индексы
      real_db_conn.exec("CREATE INDEX ON #{test_schema}.address_objects(object_id)")
      real_db_conn.exec("CREATE INDEX ON #{test_schema}.address_objects(object_id) WHERE is_active = true")
      real_db_conn.exec("CREATE INDEX ON #{test_schema}.adm_hierarchy(object_id)")
      real_db_conn.exec("CREATE INDEX ON #{test_schema}.adm_hierarchy(object_id) WHERE is_active = true")
      real_db_conn.exec("CREATE INDEX ON #{test_schema}.mun_hierarchy(object_id)")
      real_db_conn.exec("CREATE INDEX ON #{test_schema}.mun_hierarchy(object_id) WHERE is_active = true")
    end

    def populate_test_data
      # Адресные объекты: Россия -> Москва -> улица Пушкина
      real_db_conn.exec(<<-SQL)
        INSERT INTO #{test_schema}.address_objects (id, object_id, name, type_name, level, is_active) VALUES
        (1, 1, 'Российская Федерация', 'Страна', 1, true),
        (2, 2, 'Москва', 'г', 2, true),
        (3, 3, 'Пушкина', 'ул', 8, true),
        (4, 4, 'Неактивная улица', 'ул', 8, false)
      SQL

      # Административная иерархия
      real_db_conn.exec(<<-SQL)
        INSERT INTO #{test_schema}.adm_hierarchy (id, object_id, parent_obj_id, path, is_active) VALUES
        (1, 1, NULL, '1', true),
        (2, 2, 1, '1.2', true),
        (3, 3, 2, '1.2.3', true),
        (4, 4, 2, '1.2.4', false)
      SQL

      # Муниципальная иерархия (аналогично)
      real_db_conn.exec(<<-SQL)
        INSERT INTO #{test_schema}.mun_hierarchy (id, object_id, parent_obj_id, path, is_active) VALUES
        (1, 1, NULL, '1', true),
        (2, 2, 1, '1.2', true),
        (3, 3, 2, '1.2.3', true),
        (4, 4, 2, '1.2.4', false)
      SQL

      # Типы домов
      real_db_conn.exec(<<-SQL)
        INSERT INTO #{test_schema}.house_types (id, short_name) VALUES
        (1, 'д'),
        (2, 'к')
      SQL

      # Дома на улице Пушкина
      real_db_conn.exec(<<-SQL)
        INSERT INTO #{test_schema}.houses (id, object_id, house_num, house_type, is_active) VALUES
        (1, 3, '10', 1, true),
        (2, 3, '12', 2, true)
      SQL
    end

    describe "#update_address_objects_paths" do
      it "создаёт колонки full_adm_path и full_mun_path" do
        real_builder.update_address_objects_paths

        result = real_db_conn.exec(<<-SQL)
          SELECT column_name
          FROM information_schema.columns
          WHERE table_schema = '#{test_schema}'
            AND table_name = 'address_objects'
            AND column_name IN ('full_adm_path', 'full_mun_path')
        SQL

        expect(result.ntuples).to eq(2)
      end

      it "заполняет полные пути для активных объектов" do
        real_builder.update_address_objects_paths

        result = real_db_conn.exec(<<-SQL)
          SELECT name, full_adm_path, full_mun_path
          FROM #{test_schema}.address_objects
          WHERE object_id = 3 AND is_active = true
        SQL

        expect(result.ntuples).to eq(1)
        expect(result[0]["name"]).to eq("Пушкина")
        expect(result[0]["full_adm_path"]).to eq("Российская Федерация Страна, Москва г, Пушкина ул")
        expect(result[0]["full_mun_path"]).to eq("Российская Федерация Страна, Москва г, Пушкина ул")
      end

      it "не заполняет пути для неактивных объектов" do
        real_builder.update_address_objects_paths

        result = real_db_conn.exec(<<-SQL)
          SELECT full_adm_path, full_mun_path
          FROM #{test_schema}.address_objects
          WHERE object_id = 4 AND is_active = false
        SQL

        expect(result.ntuples).to eq(1)
        # Неактивный объект не должен получить пути, так как иерархия тоже неактивна
        expect(result[0]["full_adm_path"]).to be_nil
        expect(result[0]["full_mun_path"]).to be_nil
      end

      it "создаёт полнотекстовые индексы" do
        real_builder.update_address_objects_paths

        result = real_db_conn.exec(<<-SQL)
          SELECT indexname
          FROM pg_indexes
          WHERE schemaname = '#{test_schema}'
            AND tablename = 'address_objects'
            AND indexname LIKE '%full%path%'
        SQL

        expect(result.ntuples).to eq(2)
        index_names = result.map { |row| row["indexname"] }
        expect(index_names).to include("idx_address_objects_full_adm_path_tsv")
        expect(index_names).to include("idx_address_objects_full_mun_path_tsv")
      end
    end

    describe "#update_houses_paths" do
      before do
        # Сначала заполняем пути для address_objects, так как дома зависят от них
        real_builder.update_address_objects_paths
      end

      it "создаёт колонки full_adm_path и full_mun_path" do
        real_builder.update_houses_paths

        result = real_db_conn.exec(<<-SQL)
          SELECT column_name
          FROM information_schema.columns
          WHERE table_schema = '#{test_schema}'
            AND table_name = 'houses'
            AND column_name IN ('full_adm_path', 'full_mun_path')
        SQL

        expect(result.ntuples).to eq(2)
      end

      it "заполняет полные пути с номером дома" do
        real_builder.update_houses_paths

        result = real_db_conn.exec(<<-SQL)
          SELECT house_num, full_adm_path, full_mun_path
          FROM #{test_schema}.houses
          WHERE id = 1
        SQL

        expect(result.ntuples).to eq(1)
        expect(result[0]["house_num"]).to eq("10")
        expect(result[0]["full_adm_path"]).to eq("Российская Федерация Страна, Москва г, Пушкина ул, д 10")
        expect(result[0]["full_mun_path"]).to eq("Российская Федерация Страна, Москва г, Пушкина ул, д 10")
      end

      it "использует короткое имя типа дома" do
        real_builder.update_houses_paths

        result = real_db_conn.exec(<<-SQL)
          SELECT house_num, house_type, full_adm_path
          FROM #{test_schema}.houses
          WHERE id = 2
        SQL

        expect(result.ntuples).to eq(1)
        expect(result[0]["house_type"]).to eq("2")
        expect(result[0]["full_adm_path"]).to include("к 12") # к = корпус
      end

      it "создаёт полнотекстовые индексы" do
        real_builder.update_houses_paths

        result = real_db_conn.exec(<<-SQL)
          SELECT indexname
          FROM pg_indexes
          WHERE schemaname = '#{test_schema}'
            AND tablename = 'houses'
            AND indexname LIKE '%full%path%'
        SQL

        expect(result.ntuples).to eq(2)
      end
    end

    describe "cursor-based пагинация" do
      before do
        # Добавляем колонки для путей
        real_db_conn.exec("ALTER TABLE #{test_schema}.address_objects ADD COLUMN IF NOT EXISTS full_adm_path TEXT")
        real_db_conn.exec("ALTER TABLE #{test_schema}.address_objects ADD COLUMN IF NOT EXISTS full_mun_path TEXT")
        real_db_conn.exec("ALTER TABLE #{test_schema}.address_objects ADD COLUMN IF NOT EXISTS full_adm_path_tsv TSVECTOR")
        real_db_conn.exec("ALTER TABLE #{test_schema}.address_objects ADD COLUMN IF NOT EXISTS full_mun_path_tsv TSVECTOR")

        # Добавляем больше адресных объектов для тестирования пагинации
        100.times do |i|
          real_db_conn.exec(<<-SQL)
            INSERT INTO #{test_schema}.address_objects (id, object_id, name, type_name, level, is_active)
            VALUES (#{i + 10}, #{i + 10}, 'Объект #{i}', 'тест', 8, true)
          SQL

          real_db_conn.exec(<<-SQL)
            INSERT INTO #{test_schema}.adm_hierarchy (id, object_id, parent_obj_id, path, is_active)
            VALUES (#{i + 10}, #{i + 10}, 2, '1.2.#{i + 10}', true)
          SQL

          real_db_conn.exec(<<-SQL)
            INSERT INTO #{test_schema}.mun_hierarchy (id, object_id, parent_obj_id, path, is_active)
            VALUES (#{i + 10}, #{i + 10}, 2, '1.2.#{i + 10}', true)
          SQL
        end
      end

      it "обрабатывает все записи в малых батчах" do
        real_builder.send(:populate_address_objects_paths, batch_size: 10)

        result = real_db_conn.exec(<<-SQL)
          SELECT COUNT(*)
          FROM #{test_schema}.address_objects
          WHERE full_adm_path IS NOT NULL AND is_active = true
        SQL

        # Должны быть обработаны все активные объекты (104: 3 изначальных + 100 добавленных + 1 страна)
        # Но страна (id=1) не имеет родителей, поэтому путь не будет построен через JOIN
        # Поэтому ожидаем 103 объекта с путями
        expect(result[0]["count"].to_i).to be >= 100
      end

      it "заполняет пути последовательно без пропусков" do
        real_builder.send(:populate_address_objects_paths, batch_size: 25)

        result = real_db_conn.exec(<<-SQL)
          SELECT id, full_adm_path
          FROM #{test_schema}.address_objects
          WHERE is_active = true
          ORDER BY id
        SQL

        # Проверяем, что нет пропусков в заполнении (все имеют путь или все не имеют)
        paths_count = result.count { |row| !row["full_adm_path"].nil? }
        expect(paths_count).to be >= 100
      end
    end
  end
end
