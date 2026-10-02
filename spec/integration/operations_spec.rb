# frozen_string_literal: true

# Шаги загрузки из приложения (Т12, Т13): Gar.import, Gar.build_paths, Gar.switch,
# Gar.cleanup_schemas, Gar.current_version — со своей текущей схемой на пример
RSpec.describe "Загрузка из приложения", :db do
  include_context "с синтетическим архивом"

  let(:current) { isolated_schema("gar_app") }
  let(:version) { "#{current}_v20260116" }

  before { Gar.configuration.database_schema = current }

  def load_current(**)
    Gar.switch(Gar.import(zip_path, **).tap { Gar.build_paths(_1) })
  end

  it "проходит шаги по отдельности с прогрессом и делает схему текущей" do
    calls = []
    progress = ->(done, total, stage) { calls << [stage, done, total] }

    schema = Gar.import(zip_path, region_codes: ["43", "11"], on_progress: progress)
    Gar.build_paths(schema, on_progress: progress)
    Gar.switch(schema, on_progress: progress)

    expect(schema).to eq(version)
    expect(calls.map(&:first).uniq).to eq([:import, :indexes, :paths, :switch])
    expect(calls.last).to eq([:switch, 1, 1])
    expect(Gar.current_version).to have_attributes(version_id: 20_260_116, region_codes: ["11", "43"], status: "ready")
    expect(Gar.available?).to be(true)
  end

  it "без архива берёт последний из full_base_dir, а без скачанных — ConfigurationError" do
    zip_path # архив в archive_dir
    Gar.configuration.full_base_dir = archive_dir
    expect(Gar.import).to eq(version)

    Gar.configuration.full_base_dir = File.join(archive_dir, "empty")
    expect { Gar.import }.to raise_error(Gar::ConfigurationError, /Gar.download/)
  end

  it "повторный вызов шагов безопасен: загруженное не загружается заново" do
    schema   = Gar.import(zip_path)
    imported = Gar::Meta.read(db_connection, schema).imported_at

    expect(Gar.import(zip_path)).to eq(schema)
    expect(Gar::Meta.read(db_connection, schema).imported_at).to eq(imported)

    2.times { Gar.build_paths(schema) } # дозаполняет только пустые пути
    Gar.switch(schema)
    expect(Gar.import(zip_path)).to eq(current) # текущая уже из этой версии и готова
    expect(Gar.switch(current)).to eq(current)
  end

  it "заново загружает схему, загруженную с другими настройками" do
    schema   = Gar.import(zip_path, region_codes: ["43"])
    imported = Gar::Meta.read(db_connection, schema).imported_at

    Gar.import(zip_path, region_codes: ["43", "11"])

    expect(Gar::Meta.read(db_connection, schema)).to have_attributes(region_codes: ["11", "43"], imported_at: be > imported)
  end

  it "не переключает на незавершённую схему и не строит пути до конца импорта" do
    schema = Gar.import(zip_path)
    expect { Gar.switch(schema) }.to raise_error(Gar::ConfigurationError, /не готова \(imported\)/)
    expect { Gar.switch("#{current}_missing") }.to raise_error(Gar::ConfigurationError, /нет gar_meta/)

    db_connection.exec("UPDATE #{schema}.gar_meta SET status = 'importing'")
    expect { Gar.build_paths(schema) }.to raise_error(Gar::ImportError, /не завершён/)
  end

  it "пока базу изменяет другой процесс, изменяющие шаги бросают LockedError" do
    other = PG.connect(TestDatabase.url)
    other.exec_params("SELECT pg_advisory_lock(hashtext($1))", ["gar:#{current}"])

    expect { Gar.import(zip_path) }.to raise_error(Gar::LockedError, /другой процесс/)
    expect { Gar.cleanup_schemas }.to raise_error(Gar::LockedError)
    expect(Gar::Schemas.exists?(db_connection, version)).to be(false)

    other.close
    expect(Gar.import(zip_path)).to eq(version)
  ensure
    other&.close unless other&.finished?
  end

  describe "резервные схемы" do
    it "cleanup_schemas удаляет лишние резервные и устаревшие схемы импорта, текущую не трогает" do
      Gar.configuration.keep_backups = 3
      db_connection.exec("CREATE SCHEMA #{current}_backup_old")
      load_current
      load_current(region_codes: ["43"]) # прежняя текущая — резервная
      stale = Gar.import(zip_path)       # загружена, но не новее текущей

      dropped = Gar.cleanup_schemas(keep_backups: 1)

      expect(dropped).to contain_exactly("#{current}_backup_old", stale)
      expect(Gar::Schemas.backups(db_connection, current)).to eq(["#{current}_backup_v20260116"])
      expect(Gar.current_version).to have_attributes(status: "ready")
    end

    it "не удаляет схему импорта новее текущей" do
      load_current
      db_connection.exec("UPDATE #{current}.gar_meta SET version_id = 20250101")

      expect(Gar.cleanup_schemas).to eq([])
      Gar.import(zip_path)
      expect(Gar.cleanup_schemas).to eq([])
      expect(Gar::Schemas.exists?(db_connection, version)).to be(true)
    end
  end

  it "current_version — nil без текущей схемы" do
    expect(Gar.current_version).to be_nil
  end
end
