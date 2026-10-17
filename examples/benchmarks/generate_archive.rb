#!/usr/bin/env ruby
# frozen_string_literal: true

# Синтетический архив ГАР заданного объёма — для замеров импорта и поиска без реальной
# выгрузки (реальные субъекты 43 и 11 — это ≈ 2,95 ГБ XML набора :minimal).
#
#   ruby examples/benchmarks/generate_archive.rb --regions 43,11 --houses 300000 --out tmp/bench
#
# Структура архива — как у ФНС (version.txt, справочники в корне, папки субъектов, имена
# AS_<ТАБЛИЦА>_<дата>_<uuid>.XML), а файлы — только те, что загружает набор :minimal: адресные
# объекты, их параметры, обе иерархии, дома и параметры домов. Справочники — из
# Gar::TestSupport::Sample.
#
# В каждом субъекте: субъект → муниципальные округа (только в мун. иерархии) → населённые
# пункты → улицы → дома. Номера домов: 1, 2а, 3 к. 1 …; у части домов и улиц есть закрытые
# прежние записи, у домов — индекс и ОКТМО. Данные детерминированы: при тех же параметрах
# архив тот же (кроме uuid в именах файлов). XML пишется в zip потоком, память не растёт с объёмом.

require "bundler/setup"
require "gar"
require "fileutils"
require "optparse"
require "securerandom"
require "zip"

class SyntheticArchive
  FILE_DATE     = "20260115"
  SAMPLE        = Gar::TestSupport::Sample
  DATES         = Gar::TestSupport.xml_attributes(SAMPLE::DATES)
  ACTUAL        = Gar::TestSupport.xml_attributes(SAMPLE::DATES.merge(SAMPLE::ACTUAL))
  CLOSED        = Gar::TestSupport.xml_attributes(SAMPLE::DATES.merge(SAMPLE::CLOSED))
  HISTORY       = 10_000_000_000 # сдвиг ID закрытых записей
  HISTORY_EVERY = 10             # закрытая прежняя запись — у каждой десятой улицы и дома
  REGIONS       = { "43" => ["Кировская", "обл"], "11" => ["Коми", "респ"], "77" => ["Москва", "г"] }.freeze
  PLACES        = ["Заречный", "Луговой", "Сосновка", "Берёзовка", "Полянка", "Каменка", "Ольховка", "Мирный", "Озёрный", "Лесной",
                   "Ключи", "Слобода"].freeze
  STREETS       = ["Ленина", "Мира", "Советская", "Молодёжная", "Школьная", "Садовая", "Центральная", "Лесная", "Набережная",
                   "Октябрьская", "Гагарина", "Пушкина", "Кирова", "Полевая", "Заводская", "Луговая", "Советской Армии",
                   "Комсомольская", "Первомайская", "Строителей"].freeze
  STREET_TYPE   = "ул"

  # houses — домов на субъект; streets_per_place и houses_per_street задают форму дерева
  def initialize(version:, regions:, houses:, streets_per_place: 40, houses_per_street: 30)
    @version           = version
    @regions           = regions
    @houses            = houses
    @houses_per_street = houses_per_street
    @streets           = (houses.to_f / houses_per_street).ceil
    @places            = (@streets.to_f / streets_per_place).ceil
    @streets_per_place = streets_per_place
    @districts         = (@places / 10.0).ceil
  end

  def write(path)
    Zip::OutputStream.open(path) do |zip|
      zip.put_next_entry("version.txt")
      zip.write("#{@version}\nv.223")
      SAMPLE.root.each { |name, records| put(zip, nil, name) { |out| records.each { out << element(name, Gar::TestSupport.xml_attributes(_1)) } } }
      @regions.each { |code| write_region(zip, code) }
    end
    path
  end

  def summary
    "#{@regions.size} субъект(а) × (#{@districts} округов, #{@places} пунктов, #{@streets} улиц, #{@houses} домов)"
  end

  private

  def write_region(zip, code)
    base = code.to_i * 100_000_000
    put(zip, code, :address_objects) { |out| address_objects(out, code, base) }
    put(zip, code, :adm_hierarchy) { |out| hierarchy(out, code, base, mun: false) }
    put(zip, code, :mun_hierarchy) { |out| hierarchy(out, code, base, mun: true) }
    put(zip, code, :houses) { |out| houses(out, base) }
    put(zip, code, :house_params) { |out| house_params(out, base) }
    put(zip, code, :addr_obj_params) { |out| out << param_item(base, base, 16, region(code).first) }
  end

  # Идентификаторы: субъект — base, округа, пункты, улицы и дома — в своих диапазонах
  def district_id(base, index) = base + 1 + index
  def place_id(base, index)    = base + 100_000 + index
  def street_id(base, index)   = base + 1_000_000 + index
  def house_id(base, index)    = base + 10_000_000 + index

  def address_objects(out, code, base)
    name, type = region(code)
    out << object(base, %(NAME="#{name}" TYPENAME="#{type}" LEVEL="1"))
    @districts.times { out << object(district_id(base, _1), %(NAME="#{PLACES[_1 % PLACES.size]} #{_1 + 1}" TYPENAME="г.о." LEVEL="3")) }
    @places.times { out << object(place_id(base, _1), %(NAME="#{place_name(_1)}" TYPENAME="г" LEVEL="5")) }
    @streets.times do |index|
      id = street_id(base, index)
      out << object(id, %(NAME="#{street_name(index)}" TYPENAME="#{STREET_TYPE}" LEVEL="8"))
      out << closed(id, %(NAME="Старая #{index}" TYPENAME="#{STREET_TYPE}" LEVEL="8")) if (index % HISTORY_EVERY).zero?
    end
  end

  def houses(out, base)
    @houses.times do |index|
      id     = house_id(base, index)
      number = %(HOUSENUM="#{house_number(index)}" HOUSETYPE="2")
      number += ' ADDNUM1="1" ADDTYPE1="1"' if (index % 7).zero?
      out << element(:houses, %(#{record(id, id)} #{number} #{ACTUAL}))
      out << element(:houses, %(#{record(id + HISTORY, id)} #{number} #{CLOSED})) if (index % HISTORY_EVERY).zero?
    end
  end

  def house_params(out, base)
    @houses.times do |index|
      id     = house_id(base, index)
      street = index / @houses_per_street
      out << param_item((id * 10) + 5, id, 5, format("6%05d", street % 100_000))
      out << param_item((id * 10) + 7, id, 7, format("33%09d", street / @streets_per_place))
    end
  end

  # Строки иерархии: у дома — путь субъект → [округ] → пункт → улица → дом
  def hierarchy(out, code, base, mun:)
    out << item(code, [base])
    @districts.times { out << item(code, [base, district_id(base, _1)]) } if mun
    @places.times { out << item(code, place_path(base, _1, mun)) }
    @streets.times { out << item(code, place_path(base, _1 / @streets_per_place, mun) + [street_id(base, _1)]) }
    @houses.times do |index|
      street = index / @houses_per_street
      out << item(code, place_path(base, street / @streets_per_place, mun) + [street_id(base, street), house_id(base, index)])
    end
  end

  def place_path(base, place, mun)
    mun ? [base, district_id(base, place / 10), place_id(base, place)] : [base, place_id(base, place)]
  end

  def region(code) = REGIONS.fetch(code, ["Субъект #{code}", "обл"])

  def place_name(index) = index < PLACES.size ? PLACES[index] : "#{PLACES[index % PLACES.size]}-#{(index / PLACES.size) + 1}"

  def street_name(index)
    name   = STREETS[index % STREETS.size]
    serial = (index % @streets_per_place) / STREETS.size
    serial.zero? ? name : "#{serial + 1}-я #{name}"
  end

  def house_number(index)
    number = (index % @houses_per_street) + 1
    (number % 5).zero? ? "#{number}а" : number.to_s
  end

  def object(id, fields) = element(:address_objects, "#{record(id, id)} #{fields} #{ACTUAL}")
  def closed(id, fields) = element(:address_objects, "#{record(id + HISTORY, id)} #{fields} #{CLOSED}")

  # ID записи и OBJECTID объекта: у актуальной записи совпадают, у закрытой ID сдвинут на HISTORY
  def record(id, object_id)
    %(ID="#{id}" OBJECTID="#{object_id}" OBJECTGUID="#{SAMPLE.guid(object_id)}" CHANGEID="#{id}" OPERTYPEID="10")
  end

  def item(code, path)
    element(:adm_hierarchy, %(ID="#{path.last}" OBJECTID="#{path.last}" PARENTOBJID="#{path[-2] || 0}" CHANGEID="#{path.last}" ) +
                            %(REGIONCODE="#{code}" #{DATES} ISACTIVE="1" PATH="#{path.join('.')}"))
  end

  def param_item(id, object_id, type_id, value)
    element(:house_params, %(ID="#{id}" OBJECTID="#{object_id}" CHANGEID="#{id}" CHANGEIDEND="0" TYPEID="#{type_id}" ) +
                           %(VALUE="#{value}" #{DATES}))
  end

  def element(table, attributes) = "<#{Gar::Schema.fetch(table).element} #{attributes}/>"

  # Файл таблицы: записи пишутся в zip пачками по мере генерации
  def put(zip, code, table)
    file = Gar::Schema.fetch(table).file
    zip.put_next_entry([code, "AS_#{file}_#{FILE_DATE}_#{SecureRandom.uuid}.XML"].compact.join("/"))
    zip.write("﻿<?xml version=\"1.0\" encoding=\"utf-8\"?><ITEMS>")
    buffer = Buffer.new(zip)
    yield buffer
    buffer.flush
    zip.write("</ITEMS>")
  end

  # Накопитель строк перед записью в zip: меньше вызовов дефлятора
  class Buffer
    LIMIT = 1 << 20

    def initialize(io)
      @io     = io
      @buffer = +""
    end

    def <<(text)
      @buffer << text
      flush if @buffer.bytesize > LIMIT
      self
    end

    def flush
      @io.write(@buffer)
      @buffer.clear
    end
  end
end

options = { regions: ["43", "11"], houses: 300_000, out: "tmp/bench", version: "2026.01.16" }
OptionParser.new do |parser|
  parser.banner = "Использование: #{$PROGRAM_NAME} [параметры]"
  parser.on("--regions LIST", Array, "Коды субъектов (по умолчанию 43,11)") { options[:regions] = Gar::Configuration.region_codes(_1) }
  parser.on("--houses N", Integer, "Домов на субъект (по умолчанию 300000 — порядок Кировской обл.)") { options[:houses] = _1 }
  parser.on("--out DIR", "Каталог для архива (по умолчанию tmp/bench)") { options[:out] = _1 }
  parser.on("--version DATE", "Версия выгрузки в version.txt (по умолчанию 2026.01.16)") { options[:version] = _1 }
end.parse!

FileUtils.mkdir_p(options[:out])
archive = SyntheticArchive.new(version: options[:version], regions: options[:regions], houses: options[:houses])
path    = File.join(options[:out], "gar_xml_v#{options[:version].delete('.')}.zip")
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
archive.write(path)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
puts "#{path}: #{archive.summary}, #{Gar::Utils.format_size(File.size(path))}, #{elapsed.round(1)} с"
