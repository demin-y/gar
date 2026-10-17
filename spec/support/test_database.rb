# frozen_string_literal: true

require "pg"
require "securerandom"

# Тестовая БД нужна только примерам с тегом :db — spec_helper готовит её один раз и только
# если такие примеры загружены, поэтому unit-тесты работают без PostgreSQL.
module TestDatabase
  class << self
    def url
      ENV.fetch("TEST_DATABASE_URL", "postgresql://postgres:postgres@localhost:6433/gar_db_test")
    end

    def connection
      @connection = nil if @connection&.finished?
      @connection ||= PG.connect(url).tap { |conn| conn.set_notice_processor { nil } }
    end

    # База тестовая и целиком наша: удаляем схемы, оставшиеся от прерванных прогонов,
    # и загружаем тестовый набор гема (Gar::TestSupport) в схему gar
    def prepare!
      drop_schemas(connection.exec(<<~SQL).column_values(0))
        SELECT nspname FROM pg_namespace
        WHERE nspname NOT LIKE 'pg\\_%' AND nspname NOT IN ('public', 'information_schema')
      SQL
      Gar.configuration.logger = false
      Gar::TestSupport.load_fixtures(connection, schema: "gar")
    rescue PG::ConnectionBad => e
      raise "Тестовая БД недоступна (#{url}): #{e.message.strip}\n" \
            "Запустите bin/setup_test_db (или make test-db-up) либо задайте TEST_DATABASE_URL."
    end

    # Схемы и производные от них: импорт <имя>_v<версия>, резервные <имя>_backup_…
    def drop_schemas(names)
      return if names.nil?

      found = connection.exec_params("SELECT nspname FROM pg_namespace n, unnest($1::text[]) name WHERE nspname = name OR starts_with(nspname, name || '_')",
                                     [PG::TextEncoder::Array.new.encode(names)]).column_values(0)
      found.uniq.each { |name| connection.exec("DROP SCHEMA IF EXISTS #{connection.quote_ident(name)} CASCADE") }
    end

    # Соединение тестов — «соединение приложения»: в форкнутом ребёнке его отбрасывает само
    # приложение (как Active Record), гем трогает только свои
    def discard_after_fork
      @connection.socket_io.reopen(IO::NULL) unless @connection.nil? || @connection.finished?
    end

    def disconnect
      @connection&.close unless @connection&.finished?
      @connection = nil
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
