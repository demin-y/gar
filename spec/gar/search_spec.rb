# frozen_string_literal: true

# Поиск на тестовом наборе гема (схема gar, Gar::TestSupport.load_fixtures): точечные проверки
# результатов и контракта. Каскад по иерархии и автодополнение — в spec/integration/pipeline_spec.rb
RSpec.describe Gar::Search, :db do
  let(:search)      { described_class.new }
  let(:street_guid) { Gar::TestSupport::Sample.guid(4_300_011) }
  let(:house_guid)  { Gar::TestSupport::Sample.guid(4_300_104) }

  describe "#search_address_objects" do
    it "находит объект по названию и отдаёт AddressObject с обоими путями" do
      expect(search.search_address_objects("Воровского").first).to have_attributes(
        class: Gar::AddressObject, gar_object_id: 4_300_011, object_guid: street_guid, name: "Воровского", type_name: "ул",
        level: 8, full_adm_path: "Кировская обл, Киров г, Воровского ул",
        full_mun_path: "Кировская обл, город Киров г.о., Киров г, Воровского ул"
      )
    end

    it "в режиме автодополнения ищет последнее слово как префикс" do
      expect(search.search_address_objects("Воро", autocomplete: true).map(&:name)).to include("Воровского")
      expect(search.search_address_objects("Воро").map(&:name)).not_to include("Воровского")
    end

    it "на пустой запрос отвечает пустым списком без обращения к базе" do
      expect(described_class.new(instance_double(PG::Connection)).search_address_objects("  ", autocomplete: true)).to eq([])
    end
  end

  describe "#search_houses" do
    it "находит дома по пути с корпусом и отдаёт House с типом" do
      expect(search.search_houses("Киров Ленина 12 к. 2").map(&:object_guid)).to eq([house_guid])
      expect(search.find_house_by_guid(house_guid)).to have_attributes(
        class: Gar::House, gar_object_id: 4_300_104, house_num: "12", house_type: "д.",
        full_adm_path: "Кировская обл, Киров г, Ленина ул, д. 12 к. 2"
      )
    end
  end

  describe "поиск по GUID" do
    it "находит объект и возвращает nil для неизвестного или некорректного GUID" do
      expect(search.find_address_object_by_guid(street_guid).name).to eq("Воровского")
      expect(search.find_address_object_by_guid("00000000-0000-4000-8000-000000000000")).to be_nil
      expect(search.find_address_object_by_guid("не guid")).to be_nil
      expect(search.find_houses("не guid")).to eq([])
    end
  end

  it "отвергает неизвестную иерархию" do
    expect { search.search_houses("10", path_type: :geo) }.to raise_error(ArgumentError, /path_type/)
  end

  it "ищет в схеме, переданной явно" do
    expect { described_class.new(schema: "нет_такой").find_address_object_by_guid(street_guid) }.to raise_error(PG::UndefinedTable)
  end

  it "публикует событие search.gar, если загружен ActiveSupport" do
    events = []
    notifications =
      Module.new do
        define_singleton_method(:instrument) do |name, payload, &block|
          block.call(payload).tap { events << [name, payload] }
        end
      end
    stub_const("ActiveSupport::Notifications", notifications)

    search.search_address_objects("Воровского")

    expect(events).to contain_exactly(["search.gar", hash_including(method: :search_address_objects, query: "Воровского", schema: "gar", count: 1)])
  end
end
