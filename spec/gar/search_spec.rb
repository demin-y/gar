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

  describe "текстовый запрос" do
    def names(query, **) = search.search_address_objects(query, **).map(&:name)

    it "ищет слова вместе с синонимами: тип и частые слова в названиях" do
      expect(names("просп. Октябрьский")).to eq(["Октябрьский"])
      expect(names("Б. Садовая")).to eq(["Большая Садовая"])
      expect(names("улица Воровского")).to eq(["Воровского"])
    end

    it "берёт синонимы приложения без перестроения индекса" do
      expect(names("прспк Октябрьский")).to be_empty

      Gar.configuration.synonyms = { "проспект" => ["прспк"] }
      expect(names("прспк Октябрьский")).to eq(["Октябрьский"])
    end

    it "ставит точное совпадение и административный центр выше: «Кир» — сначала город Киров" do
      expect(names("Кир", autocomplete: true).first).to eq("Киров")
      expect(names("Кир", autocomplete: true)).to include("Кировский", "Кировская")
    end

    it "выше ставит объект, название которого запрос покрыл целиком: «Киров» — город, а не автодорога «Киров-Стрижи»" do
      expect(names("Киров", autocomplete: true).first(4)).to eq(["Киров", "Кировская", "Кировский", "автомобильная дорога Киров-Стрижи"])
    end

    it "отдаёт только объекты иерархии запроса: муниципальное образование — в муниципальной" do
      expect(names("город Киров")).not_to include("город Киров")
      expect(names("город Киров", hierarchy: :mun)).to include("город Киров")
    end

    it "если ничего не нашлось, повторяет запрос без типов объектов, которых нет в пути" do
      expect(names("Нововятский р-н Советская")).to eq(["Советская (Нововятский)"])
      expect(search.search_houses("Киров Нововятский р-н Советская 1").map(&:gar_object_id)).to eq([4_300_202])
      expect(names("р-н")).to be_empty
    end

    it "по шести цифрам ищет объекты с почтовым индексом и улицы его домов" do
      expect(names("610000")).to eq(["Ленина"])
      expect(names("610017")).to eq(["Ленина"])
      expect(names("999999")).to be_empty
    end
  end

  describe "границы поиска (Т6) и код субъекта (Т9)" do
    let(:kirov) { Gar::TestSupport::Sample.guid(4_300_003) }

    it "region_codes: оставляет объекты и дома только этих субъектов, код — в каждом результате" do
      expect(search.search_houses("Ленина 10").map(&:region_code)).to contain_exactly("43", "11")
      expect(search.search_houses("Ленина 10", region_codes: ["43"]).map(&:region_code)).to eq(["43"])
      expect(search.search_address_objects("Ленина", region_codes: [11]).map { [_1.name, _1.region_code] }).to eq([["Ленина", "11"]])
    end

    it "within: оставляет поддерево объекта по иерархии запроса" do
      expect(search.search_address_objects("Ленина", within: kirov).map(&:gar_object_id)).to eq([4_300_010])
      expect(search.search_houses("10", within: Gar::TestSupport::Sample.guid(1_100_001)).map(&:gar_object_id)).to eq([1_100_101])
      expect(search.find_address_objects(level: 8, within: kirov).map(&:name)).to include("Ленина", "Воровского")
      expect(search.find_house_by_guid(house_guid, within: Gar::TestSupport::Sample.guid(1_100_001))).to be_nil
    end

    it "within: принимает только GUID" do
      expect { search.search_houses("Ленина", within: "Киров") }.to raise_error(ArgumentError, /within/)
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

  describe "#find_houses" do
    it "упорядочивает номера по числу в начале, а не как текст: 5 раньше 40" do
      expect(search.find_houses(street_guid).map(&:house_num)).to eq(["5", "40", "40"])
    end
  end

  describe "поиск по GUID" do
    it "находит объект и возвращает nil для неизвестного или некорректного GUID" do
      expect(search.find_address_object_by_guid(street_guid).name).to eq("Воровского")
      expect(search.find_address_object_by_guid("00000000-0000-4000-8000-000000000000")).to be_nil
      expect(search.find_address_object_by_guid("не guid")).to be_nil
      expect(search.find_houses("не guid")).to eq([])
    end

    it "по списку GUID отдаёт Hash одним запросом, в том числе недействующие объекты (Т10)" do
      closed = Gar::TestSupport::Sample.guid(4_300_014)
      found  = search.find_address_objects_by_guids([street_guid, closed, Gar::TestSupport::Sample.guid(1), "не guid", street_guid])

      expect(found.keys).to eq([street_guid, closed])
      expect(found[street_guid]).to have_attributes(name: "Воровского", active: true)
      expect(found[closed]).to have_attributes(name: "Заводская", active: false, full_adm_path: nil)
      expect(search.find_address_objects_by_guids([street_guid, closed], region_codes: ["11"])).to eq({})
      expect(search.find_address_objects_by_guids([])).to eq({})
    end
  end

  it "отвергает неизвестную иерархию" do
    expect { search.search_houses("10", hierarchy: :geo) }.to raise_error(ArgumentError, /Иерархия — :adm или :mun/)
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
