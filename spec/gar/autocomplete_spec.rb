# frozen_string_literal: true

RSpec.describe Gar::Autocomplete, :db do
  def guid(object_id) = Gar::TestSupport::Sample.guid(object_id)
  def suggest(query, **) = Gar.autocomplete(query, **)

  it "без номера отдаёт адресные объекты по префиксу" do
    expect(suggest("Ворово").map { [_1.kind, _1.name, _1.address] })
      .to eq([[:address_object, "Воровского ул", "Кировская обл, Киров г, Воровского ул"]])
  end

  it "с номером: сначала точный номер без корпуса, затем номера с префиксом (короткие выше), затем улицы" do
    found = suggest("Киров, Ленина 10", region_codes: ["43"])

    expect(found.map(&:name)).to eq(["д. 10", "д. 10а", "д. 10/2", "Ленина ул"])
    expect(found.first).to have_attributes(kind: :house, object_guid: guid(4_300_101), gar_object_id: 4_300_101, level: 10,
                                           region_code: "43", address: "Кировская обл, Киров г, Ленина ул, д. 10")
  end

  it "учитывает корпус и строение и границы поиска" do
    expect(suggest("Ленина 14 корп 1 стр 3").first.gar_object_id).to eq(4_300_106)
    expect(suggest("Ленина 12 к2").first.gar_object_id).to eq(4_300_104)
    expect(suggest("Ленина 10a").first.gar_object_id).to eq(4_300_102) # латинская «a»
    expect(suggest("Ленина 10", within: guid(1_100_003)).map(&:gar_object_id)).to eq([1_100_101, 1_100_010])
  end

  it "ищет по иерархии запроса и отдаёт сериализуемые элементы" do
    found = suggest("Тихонова 93", hierarchy: :mun).first

    expect(found.address).to eq("Московская обл, Павлово-Посадский г.о., Павловский Посад г, Тихонова ул, д. 93")
    expect(JSON.parse(found.to_json)).to include("kind" => "house", "object_guid" => guid(44_870_981), "region_code" => "50")
  end

  it "на пустую строку отвечает пустым списком" do
    expect(suggest(" , ")).to eq([])
  end
end
