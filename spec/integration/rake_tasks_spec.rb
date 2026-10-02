# frozen_string_literal: true

require "open3"
require "rake"
require "webmock/rspec"

# Rake-задачи gar:* (Т15) — в отдельном Rake-приложении без Rails, со своей текущей схемой на пример
RSpec.describe "Rake-задачи", :db do
  include_context "с синтетическим архивом"

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
    full = "https://fias-file.nalog.ru/downloads/2026.01.16/gar_xml.zip"
    stub_request(:get, "https://fias.nalog.ru/WebServices/Public/GetAllDownloadFileInfo")
      .to_return(body: [{ VersionId: 20_260_116, GarXMLFullURL: full, GarXMLDeltaURL: "" }].to_json)
    stub_request(:get, "https://fias.nalog.ru/WebServices/Public/GetLastDownloadFileInfo")
      .to_return(body: { VersionId: 20_260_116, GarXMLFullURL: full }.to_json)
    stub_request(:get, full).to_return(body: File.binread(zip_path))

    expect(rake("gar:download")).to include("Скачивание", "Архив: #{Gar.configuration.full_base_dir}")
    expect(rake("gar:update")).to include("Полный импорт: версия — → 20260116")
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

  describe "в Rails-приложении" do
    # Отдельный процесс: Rails не должен попасть в остальные спеки
    def ruby(script)
      Dir.mktmpdir("gar_rails") do |dir|
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script, chdir: dir)
        raise "Ошибка процесса: #{stderr}" unless status.success?

        [stdout, dir]
      end
    end

    it "Railtie подключает rake-задачи, логгер гема — Rails.logger" do
      stdout, = ruby(<<~RUBY)
        require "rails"
        require "gar"
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

      expect(stdout.lines.map(&:chomp)).to eq(["gar:build_paths,gar:cleanup,gar:download,gar:environment,gar:import,gar:status,gar:switch,gar:update",
                                               "true"])
    end

    it "rails g gar:install создаёт инициализатор, который загружается без изменений настроек" do
      stdout, = ruby(<<~RUBY)
        require "rails/generators"
        require "gar"
        Rails::Generators.invoke("gar:install", [], destination_root: Dir.pwd)
        default = Gar.configuration.database_schema
        load "config/initializers/gar.rb"
        puts File.exist?("config/initializers/gar.rb"), Gar.configuration.database_schema == default
      RUBY

      expect(stdout).to include("create  config/initializers/gar.rb")
      expect(stdout.lines.last(2).map(&:chomp)).to eq(["true", "true"])
    end
  end
end
