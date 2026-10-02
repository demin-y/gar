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

  it "nil для неизвестного или некорректного GUID" do
    expect(Gar.address(guid(1))).to be_nil
    expect(Gar.address("не guid")).to be_nil
  end
end
