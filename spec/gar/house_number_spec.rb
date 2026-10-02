# frozen_string_literal: true

RSpec.describe Gar::HouseNumber do
  {
    "10"                     => ["10", nil, nil],
    "10а"                    => ["10а", nil, nil],
    "10 А"                   => ["10а", nil, nil],
    "10/2"                   => ["10/2", nil, nil],
    "10/2а"                  => ["10/2а", nil, nil],
    "10/2 а к 1"             => ["10/2а", "1", nil],
    "10к2"                   => ["10", "2", nil],
    "10 корп. 2"             => ["10", "2", nil],
    "12а к 2 стр 1"          => ["12а", "2", "1"],
    "14 корпус 1 строение 3" => ["14", "1", "3"],
    "5 стр. 1б"              => ["5", nil, "1б"],
    "10 к"                   => ["10к", nil, nil],
    "10A k2"                 => ["10а", "2", nil]
  }.each do |text, (number, building, structure)|
    it "разбирает «#{text}»" do
      expect(described_class.parse(text)).to eq(described_class.new(number:, building:, structure:))
    end
  end

  it "приводит часть номера к виду для сравнения" do
    expect(["2 А", "2a", "2А"].map { described_class.normalize(_1) }).to all(eq("2а"))
  end

  ["Ленина", "10 к 2 к 3", "10 Ленина", "", "к 2"].each do |text|
    it "не считает номером «#{text}»" do
      expect(described_class.parse(text)).to be_nil
    end
  end
end
