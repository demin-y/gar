# frozen_string_literal: true

RSpec.describe Gar::AddressBuilder, :db do
  def guid(object_id) = Gar::TestSupport::Sample.guid(object_id)

  it "собирает строку по правилам ФНС для дома из примера в правилах (муниципальное деление)" do
    address = Gar.address(guid(44_870_981), hierarchy: :mun)

    expect(address).to have_attributes(
      class: Gar::Address, gar_object_id: 44_870_981, level: 10, hierarchy: :mun, region_code: "50",
      region: "Московская область", district: "городской округ Павлово-Посадский", city: "город Павловский Посад",
      street: "улица Тихонова", house: "93",
      full_address: "Московская область, городской округ Павлово-Посадский, город Павловский Посад, улица Тихонова, дом 93",
      short_address: "Московская область, г.о. Павлово-Посадский, г Павловский Посад, ул Тихонова, д. 93"
    )
    expect(address.parent_guids).to eq([807_356, 162_142_236, 815_937, 828_325].map { guid(_1) })
    expect(address.elements.map(&:level)).to eq([1, 3, 2, 8])
    expect([address.city_element.name, address.city_element.short_type, address.street_element.short_name])
      .to eq(["Павловский Посад", "г", "ул Тихонова"])
  end

  it "для дома с корпусом и строением отдаёт все поля, индекс — от улицы" do
    expect(Gar.address(guid(4_300_106))).to have_attributes(
      region: "Кировская область", district: nil, city: "город Киров", street: "улица Ленина", house: "14", building: "1",
      structure: "3", postal_code: "610000", full_address: "Кировская область, город Киров, улица Ленина, дом 14 корпус 1 строение 3"
    )
  end

  it "берёт параметры самого дома: индекс и ОКТМО; истёкшие пропускает" do
    expect(Gar.address(guid(4_300_101))).to have_attributes(postal_code: "610017", oktmo: "33701000001", okato: nil)
  end

  it "для адресного объекта: цепочка родителей без него самого" do
    expect(Gar.address(guid(4_300_010))).to have_attributes(level: 8, street: "улица Ленина", house: nil,
                                                            parent_guids: [guid(4_300_001), guid(4_300_003)],
                                                            full_address: "Кировская область, город Киров, улица Ленина")
  end

  it "город федерального значения — и субъект, и город" do
    expect(Gar.address(guid(7_700_101))).to have_attributes(region: "город Москва", city: "город Москва", street: "улица Тверская")
  end

  describe "части адреса (Т20)" do
    it "для дома на улице города: улица и город — с GUID, названием без типа, кратким и полным типом" do
      address = Gar.address(guid(4_300_101))

      expect(address).to have_attributes(street: "улица Ленина", street_guid: guid(4_300_010), city: "город Киров",
                                         city_guid: guid(4_300_003))
      expect(address.street_element).to have_attributes(
        class: Gar::AddressElement, gar_object_id: 4_300_010, object_guid: guid(4_300_010), level: 8, name: "Ленина",
        short_type: "ул", full_type: "улица", short_name: "ул Ленина", full_name: "улица Ленина"
      )
      expect(address.city_element).to have_attributes(name: "Киров", short_type: "г", full_type: "город", level: 5)
      expect(address.elements.map(&:object_guid)).to eq(address.parent_guids)
      expect(address.elements.first).to have_attributes(level: 1, name: "Кировская", short_type: "обл", full_type: "область",
                                                        short_name: "Кировская область", full_name: "Кировская область")
    end

    it "для дома в населённом пункте без улицы: улицы нет, населённый пункт — город" do
      address = Gar.address(guid(4_300_205))

      expect(address).to have_attributes(street: nil, street_guid: nil, street_element: nil, city: "поселок Кировский",
                                         city_guid: guid(4_300_020), full_address: "Кировская область, поселок Кировский, дом 3")
      expect(address.city_element).to have_attributes(name: "Кировский", short_type: "п", full_type: "поселок", level: 6)
    end

    it "в планировочной структуре (уровень 7) улица — улица внутри неё, а без улицы — сама структура" do
      on_street = Gar.address(guid(4_300_207))
      expect(on_street).to have_attributes(street: "улица Садовая", street_guid: guid(4_300_018), city_guid: guid(4_300_003))
      expect(on_street.elements.map(&:level)).to eq([1, 5, 7, 8])
      expect(on_street.elements[2]).to have_attributes(name: "Родник", short_type: "снт", full_type: "садовое некоммерческое товарищество")

      without_street = Gar.address(guid(4_300_206))
      expect(without_street).to have_attributes(street: "садовое некоммерческое товарищество Родник", street_guid: guid(4_300_017))
      expect(without_street.street_element).to have_attributes(level: 7, name: "Родник", short_name: "снт Родник")
    end

    it "для адресного объекта элементы заканчиваются им самим" do
      address = Gar.address(guid(4_300_010))

      expect(address.elements.map(&:gar_object_id)).to eq([4_300_001, 4_300_003, 4_300_010])
      expect(address.street_element).to eq(address.elements.last)
    end

    it "сериализуется в JSON вместе с элементами" do
      json = Gar.address(guid(4_300_101)).as_json

      expect(json).to include("street_guid" => guid(4_300_010), "city_guid" => guid(4_300_003), "street" => "улица Ленина")
      expect(json["elements"].last).to eq(
        "gar_object_id" => 4_300_010, "object_guid" => guid(4_300_010), "level" => 8, "name" => "Ленина", "short_type" => "ул",
        "full_type" => "улица", "short_name" => "ул Ленина", "full_name" => "улица Ленина"
      )
    end
  end

  describe "номер дома (Т22)" do
    def addition(short_type, full_type, number) = Gar::HouseAddition.new(short_type:, full_type:, number:)

    it "литера — часть номера в регистре ГАР; Gar.match_house находит дом по ней в любом регистре (Т26)" do
      address = Gar.address(guid(4_300_108))

      expect(address).to have_attributes(house: "18Б", building: nil, structure: nil)
      expect(address.house_element).to have_attributes(
        class: Gar::HouseElement, number: "18Б", short_type: "д.", full_type: "дом", additions: [],
        short_name: "д. 18 литера Б", full_name: "дом 18 литера Б"
      )
      ["18Б", "18б"].each do |number|
        expect(Gar.match_house(street_guid: guid(4_300_010), number:)).to have_attributes(status: :exact, house: have_attributes(gar_object_id: 4_300_108))
      end
    end

    it "буква в самом номере остаётся как в ГАР (Т26)" do
      expect(Gar.address(guid(4_300_211))).to have_attributes(house: "10А")
      expect(Gar.match_house(street_guid: guid(4_300_013), number: "10а")).to have_attributes(status: :exact)
    end

    it "сооружение дополнительным номером — с типом в additions" do
      address = Gar.address(guid(4_300_208))

      expect(address).to have_attributes(house: "5", building: nil, structure: nil,
                                         full_address: "Кировская область, город Киров, улица Большая Садовая, дом 5 сооружение 1")
      expect(address.house_element.additions).to eq([addition("соор.", "сооружение", "1")])
    end

    it "тип дома — краткий и полный" do
      expect(Gar.address(guid(4_300_209)).house_element)
        .to have_attributes(number: "88", short_type: "соор.", full_type: "сооружение", short_name: "соор. 88")
    end

    it "строение типом самого дома — тип, а не часть номера: номер только в house (Т25)" do
      address = Gar.address(guid(4_300_210))

      expect(address).to have_attributes(house: "9", structure: nil, building: nil)
      expect(address.house_element).to have_attributes(short_type: "стр.", full_type: "строение", additions: [])
      expect(Gar.match_house(street_guid: guid(4_300_013), number: "9"))
        .to have_attributes(status: :exact, house: have_attributes(gar_object_id: 4_300_210))
      expect(Gar.match_house(street_guid: guid(4_300_013), number: "стр. 9")).to have_attributes(status: :exact)
      expect(Gar.match_house(street_guid: guid(4_300_013), number: "9", structure: "9")).to have_attributes(status: :none)
    end

    it "корпус и строение — в полях и в additions с типами" do
      address = Gar.address(guid(4_300_106))

      expect(address).to have_attributes(house: "14", building: "1", structure: "3")
      expect(address.house_element.additions).to eq([addition("к.", "корпус", "1"), addition("стр.", "строение", "3")])
    end

    it "у адресного объекта дома нет; в JSON дом — вложенный хэш" do
      expect(Gar.address(guid(4_300_010)).house_element).to be_nil
      expect(Gar.address(guid(4_300_208)).as_json["house_element"]).to include(
        "number" => "5", "short_type" => "д.", "additions" => [{ "short_type" => "соор.", "full_type" => "сооружение", "number" => "1" }]
      )
    end
  end

  describe "Gar.address_status (Т24)" do
    it "снесённый дом — :inactive с датой и типом операции, а Gar.address — nil" do
      expect(Gar.address(guid(4_300_107))).to be_nil
      expect(Gar.address_status(guid(4_300_107))).to have_attributes(
        class: Gar::AddressStatus, object_guid: guid(4_300_107), status: :inactive, gar_object_id: 4_300_107, level: 10,
        update_date: Date.new(2025, 6, 1), operation_type_id: 30, operation: "Ликвидация"
      )
    end

    it "упразднённая улица — :inactive" do
      expect(Gar.address_status(guid(4_300_014))).to have_attributes(status: :inactive, level: 8, update_date: Date.new(2025, 3, 1),
                                                                     operation: "Ликвидация")
    end

    it "несуществующий или некорректный GUID — :not_found" do
      expect(Gar.address_status(guid(1))).to have_attributes(status: :not_found, object_guid: guid(1), gar_object_id: nil, operation: nil)
      expect(Gar.address_status("не guid")).to have_attributes(status: :not_found)
    end

    it "действующий объект — :active; у улицы с прежним названием — по актуальной записи" do
      expect(Gar.address_status(guid(4_300_101))).to have_attributes(status: :active, level: 10, operation: "Образование")
      expect(Gar.address_status(guid(4_300_011))).to have_attributes(status: :active, gar_object_id: 4_300_011)
      expect(JSON.parse(Gar.address_status(guid(4_300_107)).to_json)).to include("status" => "inactive", "update_date" => "2025-06-01")
    end
  end

  describe "пачка GUID (Т27)" do
    let(:guids) { [guid(4_300_106), guid(4_300_010), guid(44_870_981), guid(4_300_107), guid(1), "не guid"] }

    it "Hash GUID → то же, что Gar.address по одному" do
      addresses = Gar.address(guids, hierarchy: :mun)

      expect(addresses.transform_values { _1&.gar_object_id }.values).to eq([4_300_106, 4_300_010, 44_870_981, nil, nil, nil])
      guids.each { |guid| expect(addresses[guid]).to eq(Gar.address(guid, hierarchy: :mun)) }
    end

    it "принимает любой Enumerable; некорректный GUID — nil без проверки иерархии" do
      expect(Gar.address(Set[guid(4_300_101)]).keys).to eq([guid(4_300_101)])
      expect(Gar.address("не guid", hierarchy: :нет)).to be_nil
    end
  end

  it "nil для неизвестного или некорректного GUID" do
    expect(Gar.address(guid(1))).to be_nil
    expect(Gar.address("не guid")).to be_nil
  end
end
