# frozen_string_literal: true

require "uri"

# Пользователи базы из README (Т18): импортёр загружает и переключает схемы, читатель с правами
# по умолчанию от импортёра — только ищет
RSpec.describe "Пользователи базы", :db do
  include_context "с синтетическим архивом"

  let(:suffix)   { SecureRandom.hex(4) }
  let(:importer) { "gar_importer_#{suffix}" }
  let(:reader)   { "gar_reader_#{suffix}" }
  let(:current)  { isolated_schema("gar_users") }
  let(:database) { db_connection.quote_ident(db_connection.db) }

  before do
    [importer, reader].each { db_connection.exec("CREATE ROLE #{_1} LOGIN PASSWORD 'secret'") }
    db_connection.exec("GRANT CONNECT, CREATE, TEMPORARY ON DATABASE #{database} TO #{importer}")
    db_connection.exec("GRANT CONNECT ON DATABASE #{database} TO #{reader}")
    db_connection.exec("ALTER DEFAULT PRIVILEGES FOR ROLE #{importer} GRANT USAGE ON SCHEMAS TO #{reader}")
    db_connection.exec("ALTER DEFAULT PRIVILEGES FOR ROLE #{importer} GRANT SELECT ON TABLES TO #{reader}")
    Gar.configuration.database_schema = current
  end

  after do
    Gar::Database.disconnect!
    [importer, reader].each do |role|
      db_connection.exec("DROP OWNED BY #{role} CASCADE")
      db_connection.exec("REVOKE ALL ON DATABASE #{database} FROM #{role}")
      db_connection.exec("DROP ROLE #{role}")
    end
  end

  def connect_as(role)
    url = URI(TestDatabase.url)
    url.user     = role
    url.password = "secret"
    Gar.configuration.database_url = url.to_s
  end

  it "импортёр загружает и переключает схему, читатель ищет и не может изменить базу" do
    connect_as(importer)
    load_current(region_codes: ["43"])

    connect_as(reader)
    expect(Gar.available?).to be(true)
    expect(Gar.autocomplete("Киров Ленина 12").map(&:address)).to include("Кировская обл, Киров г, Ленина ул, д. 12 к. 2")
    expect(Gar.current_version).to have_attributes(status: "ready")
    expect { Gar.import(zip_path, region_codes: ["43", "11"]) }.to raise_error(Gar::Error, /permission denied/)
  end
end
