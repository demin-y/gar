# frozen_string_literal: true

require "open3"
require "rake"
require "webmock/rspec"

# Rake-задачи gar:* (Т15) — в отдельном Rake-приложении без Rails, со своей текущей схемой на пример
RSpec.describe "Rake-задачи", :db do
  include_context "с синтетическим архивом"
  include FiasApi

  let(:current) { isolated_schema("gar_rake") }
  let(:version) { "#{current}_v20260116" }

  before do
    Gar.configuration.database_schema = current
    Gar.configuration.full_base_dir   = archive_dir
    Gar.configuration.logger          = false
    Rake.application = Rake::Application.new
    load File.expand_path("../../lib/gar/tasks/gar.rake", __dir__)
  end

  after { Rake.application = Rake::Application.new }

  # Вывод задачи; задачу можно вызывать повторно
  def rake(task, *args)
    original = $stdout
    $stdout  = StringIO.new
    Rake::Task[task].tap(&:reenable).invoke(*args)
    $stdout.string
  ensure
    $stdout = original
  end

  it "загружает выгрузку по шагам и показывает статус схем" do
    zip_path

    expect(rake("gar:status")).to include("Текущей схемы #{current} нет")
    expect(rake("gar:import", "43", "11")).to include("Импорт: 100 %", "Загружена схема #{version}")
    expect(rake("gar:build_paths", version)).to match(/Пути схемы #{version} построены: \d+ записей/)
    expect(rake("gar:switch", version)).to include("Схема #{version} стала текущей (#{current})")

    expect(rake("gar:status")).to include("Текущая схема #{current}: версия 20260116 (2026-01-16), ready", "субъекты: 11, 43")
    expect(rake("gar:import", "43", "11")).to include("уже загружена из этой выгрузки")
    expect(rake("gar:cleanup")).to include("Лишних схем нет")
  end

  it "gar:download и gar:update скачивают и загружают выгрузку из API ФНС" do
    WebMock.disable_net_connect!
    Gar.configuration.full_base_dir = File.join(archive_dir, "full")
    stub_fias_versions(20_260_116 => { full: zip_path })

    expect(rake("gar:download")).to include("Скачивание", "Архив: #{Gar.configuration.full_base_dir}")
    expect(rake("gar:update")).to include("Полный импорт (готовой текущей схемы нет): версия — → 20260116")
    expect(rake("gar:update")).to include("ГАР актуален: версия 20260116")
  ensure
    WebMock.allow_net_connect!
  end

  it "gar:switch без схемы — ConfigurationError с подсказкой" do
    expect { rake("gar:switch") }.to raise_error(Gar::ConfigurationError, /gar:status/)
  end

  it "gar:update во время другого обновления сообщает и выходит без ошибки" do
    other = Gar::Database.create_connection
    Gar::Database.with_lock(other, "Обновление ГАР") do
      expect(rake("gar:update")).to include("Обновление пропущено")
    end
  ensure
    other&.close
  end

  # Отдельный процесс: Rails не должен попасть в остальные спеки
  it "в Rails-приложении: генератор создаёт инициализатор, Railtie подключает задачи, логгер — Rails.logger" do
    script = <<~RUBY
      require "rails"
      require "rails/generators"
      require "gar"
      Rails::Generators.invoke("gar:install", [], destination_root: Dir.pwd)
      default = Gar.configuration.database_schema
      load "config/initializers/gar.rb"
      puts Gar.configuration.database_schema == default
      class GarApp < Rails::Application
        config.eager_load = false
        config.logger     = Logger.new(nil)
        config.root       = Dir.pwd
      end
      GarApp.initialize!
      GarApp.load_tasks
      puts Rake::Task.tasks.map(&:name).grep(/\\Agar:/).sort.join(",")
      puts Gar.logger.equal?(Rails.logger)
    RUBY
    lib = File.expand_path("../../lib", __dir__)
    stdout, stderr, status = Dir.mktmpdir("gar_rails") { Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script, chdir: _1) }

    expect(status).to be_success, stderr
    expect(stdout).to include("create  config/initializers/gar.rb")
    expect(stdout.lines.last(3).map(&:chomp))
      .to eq(["true", "gar:build_paths,gar:cleanup,gar:download,gar:environment,gar:import,gar:status,gar:switch,gar:update", "true"])
  end
end
