# frozen_string_literal: true

require "webmock/rspec"

# Дельты (этап 9): Gar::Delta на текущей схеме из синтетического архива (субъекты 43 и 11) и
# Gar.update! с API ФНС на WebMock. Дельта — архив той же структуры, что и полный, с
# изменёнными записями; закрытая запись приходит с ISACTUAL=0, новая — со своим ID.
RSpec.describe "Дельты", :db do
  include_context "с синтетическим архивом"

  let(:sample)  { Gar::TestSupport::Sample }
  let(:current) { isolated_schema("gar_delta") }

  before { Gar.configuration.database_schema = current }

  # Архив дельты: блок заполняет GarArchiveBuilder
  def delta(version = "2026.01.20")
    builder = GarArchiveBuilder.new(version:)
    yield builder if block_given?
    builder.write(archive_dir, name: "gar_delta_xml_v#{builder.version_id}.zip")
  end

  def apply(zip) = Gar::Delta.new(db_connection).apply(zip)

  def record(object_id, attributes)
    { "ID" => object_id, "OBJECTID" => object_id, "OBJECTGUID" => sample.guid(object_id), "CHANGEID" => object_id, "OPERTYPEID" => 20,
      **sample::DATES, **sample::ACTUAL, **attributes }
  end

  def street(object_id, name, attributes = {}) = record(object_id, { "NAME" => name, "TYPENAME" => "ул", "LEVEL" => 8, **attributes })

  def house(object_id, number, attributes = {}) = record(object_id, { "HOUSENUM" => number, "HOUSETYPE" => 2, **attributes })

  def item(object_id, path, attributes = {})
    { "ID" => object_id, "OBJECTID" => object_id, "PARENTOBJID" => path.split(".")[-2], "CHANGEID" => object_id, "REGIONCODE" => "43",
      **sample::DATES, "ISACTIVE" => "1", "PATH" => path, **attributes }
  end

  def value(sql, *params) = db_connection.exec_params(sql, params).getvalue(0, 0)

  def house_path(object_id, hierarchy = :adm)
    value("SELECT full_#{hierarchy}_path FROM #{current}.houses WHERE object_id = $1 AND is_actual", object_id)
  end

  def house_count(object_id) = value("SELECT house_count FROM #{current}.address_objects WHERE object_id = $1 AND is_actual", object_id)&.to_i

  def count(table, condition = "true") = value("SELECT count(*) FROM #{current}.#{table} WHERE #{condition}").to_i

  describe Gar::Delta do
    before { load_current(region_codes: ["43", "11"]) }

    it "переименование улицы пересобирает пути её домов, закрытые записи и параметры удаляет" do
      zip =
        delta do |d|
          d.region("43", :addr_obj, street(4_300_010, "Ленина", { **sample::CLOSED, "NEXTID" => 9_400_010 }),
                   street(4_300_010, "Свободы", { "ID" => 9_400_010, "PREVID" => 4_300_010 }))
          d.region("43", :addr_obj_params, { "ID" => 2, "OBJECTID" => 4_300_010, "CHANGEID" => 2, "CHANGEIDEND" => 99, "TYPEID" => 5,
                                             "VALUE" => "610000", **sample::DATES })
        end

      expect(apply(zip)).to eq(20_260_120)

      expect(db_connection.exec("SELECT id, name FROM #{current}.address_objects WHERE object_id = 4300010").values)
        .to eq([["9400010", "Свободы"]])
      expect(house_path(4_300_101)).to eq("Кировская обл, Киров г, Свободы ул, д. 10")
      expect(house_path(4_300_106, :mun)).to eq("Кировская обл, город Киров г.о., Киров г, Свободы ул, д. 14 к. 1 стр. 3")
      expect(count(:addr_obj_params, "id = 2")).to eq(0)
      expect(Gar.autocomplete("Свободы 10").map(&:address)).to include("Кировская обл, Киров г, Свободы ул, д. 10")
      expect(Gar.current_version).to have_attributes(version_id: 20_260_120, version_date: Date.new(2026, 1, 20), status: "ready")
      expect(described_class.history(db_connection, current))
        .to match([have_attributes(version_id: 20_260_120, version_date: Date.new(2026, 1, 20), upserted: 1, deleted: 2)])
    end

    it "новый дом получает путь и учитывается в числе домов улицы и города" do
      before = [house_count(4_300_010), house_count(4_300_003)]
      zip =
        delta do |d|
          d.region("43", :houses, house(4_300_109, "20"))
          d.region("43", :adm_hierarchy, item(4_300_109, "4300001.4300003.4300010.4300109"))
          d.region("43", :mun_hierarchy, item(4_300_109, "4300001.4300002.4300003.4300010.4300109"))
        end

      apply(zip)

      expect(house_path(4_300_109)).to eq("Кировская обл, Киров г, Ленина ул, д. 20")
      expect([house_count(4_300_010), house_count(4_300_003)]).to eq(before.map { _1 + 1 })
    end

    it "дом стал недействующим: строки иерархии удалены, в числе домов не считается" do
      before = house_count(4_300_010)
      zip =
        delta do |d|
          d.region("43", :houses, house(4_300_101, "10", { **sample::CLOSED, "NEXTID" => 9_400_101 }),
                   house(4_300_101, "10", { "ID" => 9_400_101, "ISACTIVE" => "0" }))
          [:adm_hierarchy, :mun_hierarchy].each { d.region("43", _1, item(4_300_101, "4300001.4300003.4300010.4300101", { "ISACTIVE" => "0" })) }
        end

      apply(zip)

      expect(db_connection.exec("SELECT id, is_active FROM #{current}.houses WHERE object_id = 4300101").values).to eq([["9400101", "f"]])
      expect(count(:adm_hierarchy, "object_id = 4300101") + count(:mun_hierarchy, "object_id = 4300101")).to eq(0)
      expect(house_path(4_300_101)).to be_nil
      expect(house_count(4_300_010)).to eq(before - 1)
    end

    it "перенос улицы в иерархии пересобирает пути поддерева и ранги" do
      city = house_count(4_300_003)
      village = house_count(4_300_020)
      zip =
        delta do |d|
          d.region("43", :adm_hierarchy, item(4_300_011, "4300001.4300003.4300011", { "ISACTIVE" => "0" }),
                   item(4_300_011, "4300001.4300020.4300011", { "ID" => 9_500_011 }),
                   item(4_300_201, "4300001.4300020.4300011.4300201", { "ID" => 9_500_201 }),
                   item(4_300_201, "4300001.4300003.4300011.4300201", { "ISACTIVE" => "0" }))
        end

      apply(zip)

      expect(house_path(4_300_201)).to eq("Кировская обл, Кировский п, Воровского ул, д. 5")
      expect(house_path(4_300_201, :mun)).to eq("Кировская обл, город Киров г.о., Киров г, Воровского ул, д. 5")
      expect(value("SELECT adm_path_ids FROM #{current}.houses WHERE object_id = 4300201")).to eq("{4300001,4300020,4300011,4300201}")
      expect(house_count(4_300_020)).to eq(village.to_i + 1)
      expect(house_count(4_300_003)).to eq(city) # по муниципальной иерархии дом остался в городе
    end

    it "перенос улицы без строк её домов в дельте переписывает PATH потомков (как в реальных дельтах ФНС)" do
      zip =
        delta do |d|
          d.region("43", :adm_hierarchy, item(4_300_011, "4300001.4300003.4300011", { "ISACTIVE" => "0" }),
                   item(4_300_011, "4300001.4300020.4300011", { "ID" => 9_500_011 }))
        end

      apply(zip)

      expect(value("SELECT path FROM #{current}.adm_hierarchy WHERE object_id = 4300201 AND is_active")).to eq("4300001.4300020.4300011.4300201")
      expect(house_path(4_300_201)).to eq("Кировская обл, Кировский п, Воровского ул, д. 5")
      expect(house_path(4_300_201, :mun)).to eq("Кировская обл, город Киров г.о., Киров г, Воровского ул, д. 5")
    end

    it "пропускает записи чужих субъектов и не применяет дельту повторно" do
      zip =
        delta do |d|
          d.region("43", :houses, house(4_300_102, "10б", { "ID" => 4_300_102 }))
          d.region("77", :houses, house(7_700_102, "3"))
        end

      expect(apply(zip)).to eq(20_260_120)
      expect(apply(zip)).to be_nil
      expect(apply(delta("2026.01.10"))).to be_nil

      expect(house_path(4_300_102)).to eq("Кировская обл, Киров г, Ленина ул, д. 10б")
      expect(count(:houses, "region_code = '77'")).to eq(0)
      expect(count(:gar_updates)).to eq(1)
    end

    it "в транзакции приложения применяется в ней же и откатывается вместе с ней" do
      zip = delta { _1.region("43", :addr_obj, street(4_300_010, "Свободы")) }

      expect { db_connection.transaction { raise "откат приложения" if apply(zip) } }.to raise_error("откат приложения")

      expect(value("SELECT name FROM #{current}.address_objects WHERE id = 4300010")).to eq("Ленина")
      expect(Gar.current_version.version_id).to eq(20_260_116)
    end

    it "прерванная дельта откатывается целиком" do
      zip =
        delta do |d|
          d.region("43", :addr_obj, street(4_300_010, "Свободы"))
          d.file("43/AS_HOUSES_20260120_broken.XML", "<HOUSES><HOUSE ID=")
        end

      expect { apply(zip) }.to raise_error(Gar::ImportError, /дельты/)

      expect(value("SELECT name FROM #{current}.address_objects WHERE id = 4300010")).to eq("Ленина")
      expect(Gar.current_version.version_id).to eq(20_260_116)
      expect(described_class.history(db_connection, current)).to eq([])
    end

    it "к схеме без путей применяет только записи: пути построит Gar.build_paths" do
      schema = Gar.import(zip_path, region_codes: ["43"])
      described_class.new(db_connection, schema:).apply(delta { _1.region("43", :houses, house(4_300_109, "20")) })

      expect(Gar::Meta.read(db_connection, schema)).to have_attributes(version_id: 20_260_120, status: "imported")
      expect(value("SELECT full_adm_path FROM #{schema}.houses WHERE object_id = 4300109")).to be_nil
    end

    it "пока базу изменяет другой процесс, бросает LockedError" do
      other = PG.connect(TestDatabase.url)
      other.exec_params("SELECT pg_advisory_lock(hashtext($1))", ["gar:#{current}"])

      expect { apply(delta) }.to raise_error(Gar::LockedError, /другой процесс/)
    ensure
      other&.close
    end
  end

  describe "Gar.update!" do
    include FiasApi

    before do
      WebMock.disable_net_connect!
      Gar.configure do |config|
        config.full_base_dir = File.join(archive_dir, "full")
        config.delta_dir     = File.join(archive_dir, "deltas")
      end
    end

    after { WebMock.allow_net_connect! }

    it "применяет цепочку дельт по порядку, а на последней версии ничего не делает" do
      load_current(region_codes: ["43", "11"])
      second = delta("2026.01.23") { _1.region("43", :addr_obj, street(4_300_010, "Свободы", { "ID" => 9_400_010 })) }
      first  = delta { _1.region("43", :addr_obj, street(4_300_010, "Ленина", { **sample::CLOSED, "NEXTID" => 9_400_010 })) }
      stub_fias_versions(20_260_116 => {}, 20_260_123 => { delta: second }, 20_260_120 => { delta: first })
      stages = []

      result = Gar.update!(on_progress: ->(_done, _total, stage) { stages << stage })

      expect(result).to have_attributes(kind: :delta, from_version: 20_260_116, to_version: 20_260_123, versions: [20_260_120, 20_260_123])
      expect(stages.uniq).to eq([:download, :delta])
      expect(house_path(4_300_101)).to eq("Кировская обл, Киров г, Свободы ул, д. 10")
      expect(Gar.update!).to have_attributes(kind: :none, from_version: 20_260_123, versions: [])
    end

    it "без базы загружает последнюю выгрузку полным импортом" do
      stub_fias_versions(20_260_116 => { full: zip_path })

      expect(Gar.update!).to have_attributes(kind: :full, from_version: nil, to_version: 20_260_116)
      expect(Gar.current_version).to have_attributes(status: "ready", region_codes: [])
      expect(Gar.available?).to be(true)
    end

    it "при разрыве цепочки или слишком длинной цепочке переходит на полный импорт" do
      load_current(region_codes: ["43", "11"])
      full = GarSampleArchive.build(version: "2026.01.20").write(archive_dir, name: "gar_xml_v20260120.zip")
      stub_fias_versions(20_260_110 => {}, 20_260_120 => { delta: delta, full: })

      expect(Gar.update!).to have_attributes(kind: :full, from_version: 20_260_116, to_version: 20_260_120)
      expect(Gar::Schemas.backups(db_connection, current)).to eq(["#{current}_backup_v20260116"])

      Gar.configuration.max_delta_chain = 0
      newer = GarSampleArchive.build(version: "2026.01.23").write(archive_dir, name: "gar_xml_v20260123.zip")
      stub_fias_versions(20_260_120 => {}, 20_260_123 => { delta: delta("2026.01.23"), full: newer })
      expect(Gar.update!).to have_attributes(kind: :full, from_version: 20_260_120, to_version: 20_260_123)
      expect(Gar.current_version.version_id).to eq(20_260_123)
    end
  end
end
