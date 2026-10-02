# frozen_string_literal: true

require "stringio"

RSpec.describe Gar::XmlReader do
  let(:houses) { Gar::Schema.fetch(:houses) }

  def xml(root, *items)
    %(﻿<?xml version="1.0" encoding="utf-8"?><#{root}>#{items.join}</#{root}>)
  end

  # Поток, который отдаёт данные мелкими кусками, как сеть или распаковщик
  def trickle(string, piece = 7)
    io = StringIO.new(string.b)
    Object.new.tap { |obj| obj.define_singleton_method(:read) { |length| io.read([length, piece].min) } }
  end

  def read(table, content, **options)
    chunks = []
    count  = described_class.new(table, **options).read(StringIO.new(content.b)) { chunks << _1 }
    [count, chunks.join]
  end

  def copy_line(table, attributes, region_code = nil)
    values = table.columns.map { attributes.fetch(_1.attribute, "\\N") }
    values << region_code if table.region_code
    "#{values.join("\t")}\n"
  end

  it "превращает записи в строки COPY по колонкам таблицы, опущенные атрибуты — NULL, в конце — код субъекта" do
    house = { "ID" => "1", "OBJECTID" => "10", "OBJECTGUID" => "00000000-0000-4000-8000-000000000010", "CHANGEID" => "5",
              "HOUSENUM" => "12", "ADDNUM1" => "2", "HOUSETYPE" => "2", "ADDTYPE1" => "1", "OPERTYPEID" => "10",
              "UPDATEDATE" => "2024-01-01", "STARTDATE" => "2024-01-01", "ENDDATE" => "2079-06-06",
              "ISACTUAL" => "1", "ISACTIVE" => "1" }
    content = xml("HOUSES", %(<HOUSE #{house.map { |key, value| %(#{key}="#{value}") }.join(' ')} />))

    expect(read(houses, content, region_code: "43")).to eq([1, copy_line(houses, house, "43")])
  end

  it "пустое значение атрибута считает NULL" do
    _, lines = read(houses, xml("HOUSES", '<HOUSE ID="1" HOUSENUM="" />'), region_code: "43")

    expect(lines.split("\t").first(5)).to eq(["1", '\\N', '\\N', '\\N', '\\N'])
  end

  it "раскрывает сущности XML и экранирует спецсимволы COPY" do
    objects = Gar::Schema.fetch(:address_objects)
    content = xml("ADDRESSOBJECTS", %(<OBJECT ID="1" NAME="&quot;Мир&quot; &amp; труд\\1&#9;2" TYPENAME="ул" />))

    _, lines = read(objects, content, region_code: "11")

    expect(lines.split("\t", 6)[4]).to eq(%("Мир" & труд\\\\1\\t2))
    expect(lines.encoding).to eq(Encoding::UTF_8)
  end

  it "пропускает чужие элементы и атрибуты, которых нет среди колонок" do
    content = xml("HOUSES", '<HOUSE ID="1" FOO="x" />', '<OTHER ID="2" />')

    expect(read(houses, content, region_code: "43")).to eq([1, copy_line(houses, { "ID" => "1" }, "43")])
  end

  it "отбрасывает записи, не прошедшие фильтры" do
    params  = Gar::Schema.fetch(:house_params)
    content = xml("PARAMS", '<PARAM ID="1" TYPEID="5" CHANGEIDEND="0" />', '<PARAM ID="2" TYPEID="8" CHANGEIDEND="0" />',
                  '<PARAM ID="3" TYPEID="7" CHANGEIDEND="12" />', '<PARAM ID="4" TYPEID="7" CHANGEIDEND="0" />')

    count, lines = read(params, content, filters: { "CHANGEIDEND" => [0], "TYPEID" => [5, 7] })

    expect(count).to eq(2)
    expect(lines.lines.map { _1.split("\t").first }).to eq(["1", "4"])
  end

  it "у справочника без кода субъекта строка кончается последней колонкой" do
    types = Gar::Schema.fetch(:house_types)
    count, lines = read(types, xml("HOUSETYPES", '<HOUSETYPE ID="2" NAME="Дом" SHORTNAME="д." ISACTIVE="true" />'))

    expect([count, lines]).to eq([1, "2\tДом\tд.\t\\N\t\\N\t\\N\t\\N\ttrue\n"])
  end

  it "читает поток кусками и отдаёт строки порциями около CHUNK_SIZE" do
    records = Array.new(3_000) { |index| %(<HOUSE ID="#{index}" HOUSENUM="#{'9' * 20}" ISACTUAL="1" />) }
    chunks  = []

    count = described_class.new(houses, region_code: "43").read(trickle(xml("HOUSES", *records))) { chunks << _1 }

    expect(count).to eq(3_000)
    expect(chunks.size).to be > 1
    expect(chunks[0...-1].map(&:bytesize)).to all(be_between(described_class::CHUNK_SIZE, described_class::CHUNK_SIZE + 200))
    expect(chunks.join.lines.map { _1.split("\t").first.to_i }).to eq((0...3_000).to_a)
  end

  it "для файла без записей ничего не отдаёт" do
    expect(read(houses, %(<?xml version="1.0" encoding="utf-8"?><HOUSES />))).to eq([0, ""])
  end

  it "бросает ImportError на повреждённом XML, а не теряет записи молча" do
    expect { read(houses, xml("HOUSES", '<HOUSE ID="1" />')[0...-3]) }
      .to raise_error(Gar::ImportError, /Ошибка разбора XML.*not terminated/)
  end
end
