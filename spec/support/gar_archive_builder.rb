# frozen_string_literal: true

require "zip"
require "securerandom"
require "tmpdir"

# Синтетический архив ГАР с реальной структурой (см. docs/gar_archive_structure.md):
# version.txt, 10 справочников в корне, в каждой папке субъекта — все 18 файлов.
# Файл без записей пишется с пустым корневым элементом, атрибуты со значением nil опускаются,
# в начале каждого XML — BOM, как в выгрузках ФНС.
#
#   builder = GarArchiveBuilder.new(version: "2026.01.16")
#   builder.root(:house_types, { "ID" => 2, "NAME" => "Дом", ... })
#   builder.region("43", :houses, { "ID" => 1, "OBJECTID" => 10, ... })
#   zip_path = builder.write(dir)
class GarArchiveBuilder
  ROOT_FILES = {
    addhouse_types:       ["AS_ADDHOUSE_TYPES", "HOUSETYPES", "HOUSETYPE"],
    addr_obj_types:       ["AS_ADDR_OBJ_TYPES", "ADDRESSOBJECTTYPES", "ADDRESSOBJECTTYPE"],
    apartment_types:      ["AS_APARTMENT_TYPES", "APARTMENTTYPES", "APARTMENTTYPE"],
    house_types:          ["AS_HOUSE_TYPES", "HOUSETYPES", "HOUSETYPE"],
    normative_docs_kinds: ["AS_NORMATIVE_DOCS_KINDS", "NDOCKINDS", "NDOCKIND"],
    normative_docs_types: ["AS_NORMATIVE_DOCS_TYPES", "NDOCTYPES", "NDOCTYPE"],
    object_levels:        ["AS_OBJECT_LEVELS", "OBJECTLEVELS", "OBJECTLEVEL"],
    operation_types:      ["AS_OPERATION_TYPES", "OPERATIONTYPES", "OPERATIONTYPE"],
    param_types:          ["AS_PARAM_TYPES", "PARAMTYPES", "PARAMTYPE"],
    room_types:           ["AS_ROOM_TYPES", "ROOMTYPES", "ROOMTYPE"]
  }.freeze

  REGION_FILES = {
    addr_obj:          ["AS_ADDR_OBJ", "ADDRESSOBJECTS", "OBJECT"],
    addr_obj_division: ["AS_ADDR_OBJ_DIVISION", "ITEMS", "ITEM"],
    addr_obj_params:   ["AS_ADDR_OBJ_PARAMS", "PARAMS", "PARAM"],
    adm_hierarchy:     ["AS_ADM_HIERARCHY", "ITEMS", "ITEM"],
    apartments:        ["AS_APARTMENTS", "APARTMENTS", "APARTMENT"],
    apartments_params: ["AS_APARTMENTS_PARAMS", "PARAMS", "PARAM"],
    carplaces:         ["AS_CARPLACES", "CARPLACES", "CARPLACE"],
    carplaces_params:  ["AS_CARPLACES_PARAMS", "PARAMS", "PARAM"],
    change_history:    ["AS_CHANGE_HISTORY", "ITEMS", "ITEM"],
    houses:            ["AS_HOUSES", "HOUSES", "HOUSE"],
    houses_params:     ["AS_HOUSES_PARAMS", "PARAMS", "PARAM"],
    mun_hierarchy:     ["AS_MUN_HIERARCHY", "ITEMS", "ITEM"],
    normative_docs:    ["AS_NORMATIVE_DOCS", "NORMDOCS", "NORMDOC"],
    reestr_objects:    ["AS_REESTR_OBJECTS", "REESTR_OBJECTS", "OBJECT"],
    rooms:             ["AS_ROOMS", "ROOMS", "ROOM"],
    rooms_params:      ["AS_ROOMS_PARAMS", "PARAMS", "PARAM"],
    steads:            ["AS_STEADS", "STEADS", "STEAD"],
    steads_params:     ["AS_STEADS_PARAMS", "PARAMS", "PARAM"]
  }.freeze

  XML_ESCAPES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;" }.freeze

  attr_reader :version

  # version   — содержимое version.txt (дата выгрузки); file_date — дата в именах файлов,
  # в реальных архивах она не совпадает с версией
  def initialize(version: "2026.01.16", file_date: "20260115")
    @version   = version
    @file_date = file_date
    @root      = Hash.new { |hash, table| hash[table] = [] }
    @regions   = Hash.new { |hash, code| hash[code] = Hash.new { |files, table| files[table] = [] } }
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

  def write(dir = Dir.mktmpdir("gar_archive"), name: "gar_xml_v#{version_id}.zip")
    path = File.join(dir, name)

    Zip::OutputStream.open(path) do |zip|
      put(zip, "version.txt", "#{version}\nv.223")
      ROOT_FILES.each { |table, spec| put(zip, file_name(nil, spec), xml(spec, @root[table])) }

      @regions.sort.each do |code, files|
        REGION_FILES.each { |table, spec| put(zip, file_name(code, spec), xml(spec, files[table])) }
      end
    end

    path
  end

  private

  def put(zip, name, content)
    zip.put_next_entry(name)
    zip.write(content)
  end

  def file_name(region_code, (prefix, _root, _item))
    name = "#{prefix}_#{@file_date}_#{SecureRandom.uuid}.XML"
    region_code ? "#{region_code}/#{name}" : name
  end

  def xml((_prefix, root, item), records)
    body = records.map { |record| "<#{item} #{attributes(record)} />" }.join
    %(﻿<?xml version="1.0" encoding="utf-8"?><#{root}>#{body}</#{root}>)
  end

  def attributes(record)
    record.filter_map { |key, value| %(#{key}="#{value.to_s.gsub(/[&<>"]/, XML_ESCAPES)}") unless value.nil? }.join(" ")
  end
end
