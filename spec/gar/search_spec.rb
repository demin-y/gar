# frozen_string_literal: true

# Поиск на фикстурах (схема gar, spec/fixtures): точечные проверки результатов и контракта.
# Каскад по иерархии и автодополнение на связном наборе — в spec/integration/pipeline_spec.rb
RSpec.describe Gar::Search, :db do
  let(:search)      { described_class.new }
  let(:street_guid) { "ade36438-cc47-4b4f-92a4-c7cb5ed42b92" }
  let(:house_guid)  { "923290c1-5aa0-43ec-8bf2-3ba3b06f8b66" }

  describe "#search_address_objects" do
    it "находит объект по названию и отдаёт AddressObject с обоими путями" do
      expect(search.search_address_objects("Зимняя").first).to have_attributes(
        class: Gar::AddressObject, object_guid: street_guid, name: "Зимняя", type_name: "ул.", level: 8,
        full_adm_path: "Вологодская обл., Великоустюгский р-н, Куликово д., Зимняя ул.",
        full_mun_path: "Вологодская обл., Великоустюгский м.о., Куликово д., Зимняя ул."
      )
    end

    it "в режиме автодополнения ищет последнее слово как префикс" do
      expect(search.search_address_objects("Зи", autocomplete: true).map(&:name)).to include("Зимняя")
      expect(search.search_address_objects("Зи").map(&:name)).not_to include("Зимняя")
    end

    it "на пустой запрос отвечает пустым списком без обращения к базе" do
      expect(described_class.new(instance_double(PG::Connection)).search_address_objects("  ", autocomplete: true)).to eq([])
    end
  end

  describe "#search_houses" do
    it "находит дома по пути и отдаёт House с типом" do
      expect(search.search_houses("Канаш Лермонтова 2").map(&:object_guid)).to include(house_guid)
      expect(search.find_house_by_guid(house_guid)).to have_attributes(class: Gar::House, house_num: "2", house_type: "д.")
    end
  end

  describe "поиск по GUID" do
    it "находит объект и возвращает nil для неизвестного или некорректного GUID" do
      expect(search.find_address_object_by_guid(street_guid).name).to eq("Зимняя")
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

    search.search_address_objects("Зимняя")

    expect(events).to contain_exactly(["search.gar", hash_including(method: :search_address_objects, query: "Зимняя", schema: "gar", count: 1)])
  end
end
