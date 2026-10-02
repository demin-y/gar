# frozen_string_literal: true

require "pg"
require "securerandom"

# Тестовая БД нужна только примерам с тегом :db — spec_helper готовит её один раз и только
# если такие примеры загружены, поэтому unit-тесты работают без PostgreSQL.
module TestDatabase
  FIXTURES_DIR = File.expand_path("../fixtures", __dir__)

  class << self
    def url
      ENV.fetch("TEST_DATABASE_URL", "postgresql://postgres:postgres@localhost:6433/gar_db_test")
    end

    def connection
      @connection = nil if @connection&.finished?
      @connection ||= PG.connect(url).tap { |conn| conn.set_notice_processor { nil } }
    end

    # База тестовая и целиком наша: удаляем схемы, оставшиеся от прерванных прогонов,
    # и заливаем фикстуры в схему gar
    def prepare!
      drop_schemas(connection.exec(<<~SQL).column_values(0))
        SELECT nspname FROM pg_namespace
        WHERE nspname NOT LIKE 'pg\\_%' AND nspname NOT IN ('public', 'information_schema')
      SQL
      load_fixtures
    rescue PG::ConnectionBad => e
      raise "Тестовая БД недоступна (#{url}): #{e.message.strip}\n" \
            "Запустите bin/setup_test_db (или make test-db-up) либо задайте TEST_DATABASE_URL."
    end

    def drop_schemas(names)
      names&.each { |name| connection.exec("DROP SCHEMA IF EXISTS #{connection.quote_ident(name)} CASCADE") }
    end

    def disconnect
      @connection&.close unless @connection&.finished?
      @connection = nil
    end

    private

    # Отдельное соединение: schema.sql меняет search_path сессии
    def load_fixtures
      conn = PG.connect(url)
      conn.set_notice_processor { nil }
      conn.exec(File.read(File.join(FIXTURES_DIR, "schema.sql")))
      conn.exec(File.read(File.join(FIXTURES_DIR, "data.sql")))
    ensure
      conn&.close
    end
  end

  module Helpers
    def db_connection
      TestDatabase.connection
    end

    # Уникальное имя схемы; схема удаляется после примера
    def isolated_schema(prefix)
      register_schema_for_cleanup("#{prefix}_#{SecureRandom.hex(4)}")
    end

    def register_schema_for_cleanup(name)
      (@schemas_to_drop ||= []) << name
      name
    end

    def schema_exists?(name)
      db_connection.exec_params("SELECT 1 FROM pg_namespace WHERE nspname = $1", [name]).ntuples.positive?
    end

    def tables_in(schema)
      db_connection.exec_params("SELECT tablename FROM pg_tables WHERE schemaname = $1", [schema]).column_values(0).map(&:to_sym)
    end

    def table_count(schema, table)
      db_connection.exec("SELECT COUNT(*) FROM #{db_connection.quote_ident(schema)}.#{table}").getvalue(0, 0).to_i
    end
  end
end
