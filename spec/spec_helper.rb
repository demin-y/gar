# frozen_string_literal: true

unless ENV["COVERAGE"] == "0"
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
  end
end

require "bundler/setup"
require "gar"

Dir[File.join(__dir__, "support/**/*.rb")].each { |file| require file }

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  config.order = :random
  Kernel.srand config.seed

  # :slow — средний синтетический объём; локально выключены, в CI включены (GAR_SLOW_TESTS=1)
  config.filter_run_excluding :slow unless ENV["GAR_SLOW_TESTS"]

  config.include TestDatabase::Helpers, :db
  config.before(:context, :db) { TestDatabase.prepare! }
  config.after(:each, :db) { TestDatabase.drop_schemas(@schemas_to_drop) }
  config.after(:suite) { TestDatabase.disconnect }

  # Каждый пример начинает со свежей конфигурацией гема
  config.around do |example|
    Gar.instance_variable_set(:@configuration, nil)
    Gar.configure do |gar|
      gar.database_url    = TestDatabase.url
      gar.parallel_import = false # параллельный импорт проверяют отдельные примеры
      gar.logger          = false unless ENV["GAR_TEST_LOG"]
    end
    example.run
  ensure
    Gar::Database.disconnect!
    Gar.instance_variable_set(:@configuration, nil)
  end
end
