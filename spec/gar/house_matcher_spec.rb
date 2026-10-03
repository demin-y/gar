# frozen_string_literal: true

# Сопоставление на улице Ленина тестового набора: дома 10, 10а, 10/2, 12 к. 2, 12 стр. 1,
# 14 к. 1 стр. 3, 18 литера Б и снесённый 16 (Gar::TestSupport::Sample)
RSpec.describe Gar::HouseMatcher, :db do
  def guid(object_id) = Gar::TestSupport::Sample.guid(object_id)
  def match(number, street: 4_300_010, **) = Gar.match_house(street_guid: guid(street), number:, **)

  # Запись старого адреса → статус и OBJECTID найденного дома
  {
    ["10"]                                    => [:exact, 4_300_101],
    ["10а"]                                   => [:exact, 4_300_102],
    ["10 А"]                                  => [:exact, 4_300_102],
    ["10a"]                                   => [:exact, 4_300_102], # латинская «a»
    ["10", { letter: "А" }]                   => [:exact, 4_300_102],
    ["10/2"]                                  => [:exact, 4_300_103],
    ["д. 10"]                                 => [:exact, 4_300_101],
    ["12", { building: "2" }]                 => [:exact, 4_300_104],
    ["12 корп. 2"]                            => [:exact, 4_300_104],
    ["12к2"]                                  => [:exact, 4_300_104],
    ["12", { structure: 1 }]                  => [:exact, 4_300_105],
    ["14", { building: "1", structure: "3" }] => [:exact, 4_300_106],
    ["18б"]                                   => [:exact, 4_300_108], # литера — часть номера
    ["18", { letter: "Б" }]                   => [:exact, 4_300_108],
    ["18 лит. Б"]                             => [:exact, 4_300_108], # литера словом
    ["д. 10, кв. 5"]                          => [:exact, 4_300_101], # помещение отбрасывается
    ["14"]                                    => [:fuzzy, 4_300_106], # единственный 14, у него корпус и строение
    ["14", { building: "1" }]                 => [:fuzzy, 4_300_106],
    ["12"]                                    => [:none, nil],        # 12 к. 2 и 12 стр. 1 — неоднозначно
    ["12", { building: "3" }]                 => [:none, nil],
    ["14", { building: "2" }]                 => [:none, nil],
    ["10б"]                                   => [:none, nil],
    ["18"]                                    => [:none, nil],
    ["16"]                                    => [:none, nil],        # снесён
    ["99"]                                    => [:none, nil],
    [""]                                      => [:none, nil]
  }.each do |(number, parts), (status, object_id)|
    it "«#{number}» #{parts&.inspect} → #{status}" do
      expect(match(number, **parts.to_h)).to have_attributes(status:, house: object_id && have_attributes(gar_object_id: object_id))
    end
  end

  it "отдаёт альтернативы — другие дома улицы с тем же числом в номере" do
    expect(match("10").alternatives.map(&:gar_object_id)).to eq([4_300_102, 4_300_103])
    expect(match("12").alternatives.map(&:gar_object_id)).to contain_exactly(4_300_104, 4_300_105)
    expect(match("99").alternatives).to eq([])
  end

  it "ищет только на заданной улице, в т. ч. по муниципальной иерархии" do
    expect(match("10", street: 1_100_010).house.gar_object_id).to eq(1_100_101)
    expect(match("5", street: 4_300_010).status).to eq(:none)
    expect(match("93", street: 828_325, hierarchy: :mun)).to have_attributes(status: :exact, house: have_attributes(gar_object_id: 44_870_981))
  end

  it "из домов с одним номером («д. 40» и «зд. 40») выбирает тип «дом»" do
    expect(match("40", street: 4_300_011)).to have_attributes(status: :exact, house: have_attributes(gar_object_id: 4_300_204))
    expect(match("40", street: 4_300_011).alternatives.map(&:gar_object_id)).to eq([4_300_203])
  end

  it "для неизвестной улицы или некорректного GUID — :none" do
    expect(match("10", street: 1)).to have_attributes(status: :none, house: nil, alternatives: [])
    expect(Gar.match_house(street_guid: "не guid", number: "10").status).to eq(:none)
  end

  it "сериализуется в JSON вместе с домами" do
    json = JSON.parse(match("12").to_json)

    expect(json).to include("status" => "none", "house" => nil)
    expect(json["alternatives"].map { _1["house_num"] }).to eq(["12", "12"])
  end
end
