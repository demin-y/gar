# frozen_string_literal: true

require "zip"
require "securerandom"

# Синтетический архив ГАР с реальной структурой (см. docs/gar_archive_structure.md):
# version.txt, 10 справочников в корне, в каждой папке субъекта — все 18 файлов.
# Файл без записей пишется с пустым корневым элементом, атрибуты со значением nil опускаются,
# в начале каждого XML — BOM, как в выгрузках ФНС.
#
#   builder = GarArchiveBuilder.new(version: "2026.01.16")
#   builder.root(:house_types, { "ID" => 2, "NAME" => "Дом", ... })
#   builder.region("43", :houses, { "ID" => 1, "OBJECTID" => 10, ... })
#   zip_path = builder.write(Dir.mktmpdir)
class GarArchiveBuilder
  ROOT_FILES = {
    addhouse_types:       ["HOUSETYPES", "HOUSETYPE"],
    addr_obj_types:       ["ADDRESSOBJECTTYPES", "ADDRESSOBJECTTYPE"],
    apartment_types:      ["APARTMENTTYPES", "APARTMENTTYPE"],
    house_types:          ["HOUSETYPES", "HOUSETYPE"],
    normative_docs_kinds: ["NDOCKINDS", "NDOCKIND"],
    normative_docs_types: ["NDOCTYPES", "NDOCTYPE"],
    object_levels:        ["OBJECTLEVELS", "OBJECTLEVEL"],
    operation_types:      ["OPERATIONTYPES", "OPERATIONTYPE"],
    param_types:          ["PARAMTYPES", "PARAMTYPE"],
    room_types:           ["ROOMTYPES", "ROOMTYPE"]
  }.freeze

  REGION_FILES = {
    addr_obj:          ["ADDRESSOBJECTS", "OBJECT"],
    addr_obj_division: ["ITEMS", "ITEM"],
    addr_obj_params:   ["PARAMS", "PARAM"],
    adm_hierarchy:     ["ITEMS", "ITEM"],
    apartments:        ["APARTMENTS", "APARTMENT"],
    apartments_params: ["PARAMS", "PARAM"],
    carplaces:         ["CARPLACES", "CARPLACE"],
    carplaces_params:  ["PARAMS", "PARAM"],
    change_history:    ["ITEMS", "ITEM"],
    houses:            ["HOUSES", "HOUSE"],
    houses_params:     ["PARAMS", "PARAM"],
    mun_hierarchy:     ["ITEMS", "ITEM"],
    normative_docs:    ["NORMDOCS", "NORMDOC"],
    reestr_objects:    ["REESTR_OBJECTS", "OBJECT"],
    rooms:             ["ROOMS", "ROOM"],
    rooms_params:      ["PARAMS", "PARAM"],
    steads:            ["STEADS", "STEAD"],
    steads_params:     ["PARAMS", "PARAM"]
  }.freeze

  # В реальных архивах дата в именах файлов не совпадает с версией выгрузки
  FILE_DATE = "20260115"

  attr_reader :version

  # version — содержимое version.txt (дата выгрузки)
  def initialize(version: "2026.01.16")
    @version   = version
    @root      = Hash.new { |hash, table| hash[table] = [] }
    @regions   = Hash.new { |hash, code| hash[code] = Hash.new { |files, table| files[table] = [] } }
    @extra     = {}
  end

  def version_id
    version.delete(".").to_i
  end

  def root(table, *records)
    raise ArgumentError, "Неизвестный справочник: #{table}" unless ROOT_FILES.key?(table)

    @root[table].concat(records)
    self
  end

  # Без таблицы — просто создаёт папку субъекта (все 18 файлов будут пустыми)
  def region(code, table = nil, *records)
    files = @regions[code]
    return self unless table
    raise ArgumentError, "Неизвестная таблица субъекта: #{table}" unless REGION_FILES.key?(table)

    files[table].concat(records)
    self
  end

  # Произвольный файл архива (посторонние файлы, файлы не на своём месте)
  def file(name, content)
    @extra[name] = content
    self
  end

  # version_txt: nil — архив без version.txt
  def write(dir, name: "gar_xml_v#{version_id}.zip", version_txt: "#{version}\nv.223")
    path = File.join(dir, name)

    Zip::OutputStream.open(path) do |zip|
      put(zip, "version.txt", version_txt) if version_txt
      ROOT_FILES.each { |table, elements| put(zip, file_name(nil, table), xml(elements, @root[table])) }

      @regions.sort.each do |code, files|
        REGION_FILES.each { |table, elements| put(zip, file_name(code, table), xml(elements, files[table])) }
      end
      @extra.each { |entry, content| put(zip, entry, content) }
    end

    path
  end

  private

  def put(zip, name, content)
    zip.put_next_entry(name)
    zip.write(content)
  end

  # Ключи таблиц совпадают с именами файлов ФНС: :houses_params → AS_HOUSES_PARAMS
  def file_name(region_code, table)
    name = "AS_#{table.to_s.upcase}_#{FILE_DATE}_#{SecureRandom.uuid}.XML"
    region_code ? "#{region_code}/#{name}" : name
  end

  def xml((root, item), records)
    body = records.map { |record| "<#{item} #{attributes(record)} />" }.join
    %(﻿<?xml version="1.0" encoding="utf-8"?><#{root}>#{body}</#{root}>)
  end

  def attributes(record)
    record.filter_map { |key, value| "#{key}=#{value.to_s.encode(xml: :attr)}" unless value.nil? }.join(" ")
  end
end
