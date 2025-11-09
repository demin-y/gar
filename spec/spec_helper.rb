# frozen_string_literal: true

require "bundler/setup"
require "mini_sql"
require "gar"
require "pg"
require "json"
require_relative "support/gar_archive_helper"

module IntegrationTestHelper
  class << self
    def database_url
      ENV.fetch("TEST_DATABASE_URL", "postgresql://postgres:postgres@localhost:6433/gar_db_test")
    end

    def setup_database
      reset_connection
      ensure_docker_running
    end

    def teardown_database
      reset_connection
      # Оставляем test БД запущенной для возможности ручной отладки
      # Если нужно останавливать, раскомментируйте:
      # system("docker-compose stop db-test", out: File::NULL, err: File::NULL)
    end

    def connection
      @connection ||= PG.connect(database_url)
    end

    def reset_connection
      @connection&.close
      @connection = nil
    end

    private

    def ensure_docker_running
      system("docker-compose up -d db-test", out: File::NULL, err: File::NULL)
      wait_for_database
    end

    def wait_for_database
      max_attempts = 30
      attempt = 0

      loop do
        attempt += 1
        begin
          connection.exec("SELECT 1")
          puts "Test БД готова к работе (попытка #{attempt})"
          break
        rescue PG::ConnectionBad, PG::Error => e
          @connection = nil

          raise "Не удалось подключиться к test БД после #{max_attempts} попыток: #{e.message}" if attempt >= max_attempts

          sleep 1
        end
      end
    end
  end
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Автоматический запуск/остановка тестовой базы данных
  config.before(:suite) do
    IntegrationTestHelper.setup_database
    Gar.configuration.database_url = IntegrationTestHelper.database_url

    # Отключаем параллельный импорт в CI для стабильности тестов
    if ENV["CI"]
      Gar.configuration.parallel_import = false
      puts "CI detected: parallel import disabled for test stability"
    end
  end

  config.after(:suite) do
    IntegrationTestHelper.teardown_database
  end
end
