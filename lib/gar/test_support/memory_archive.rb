# frozen_string_literal: true

require "stringio"

module Gar
  module TestSupport
    # Архив ГАР в памяти для Importer: те же работы «таблица × субъект» и фильтры, что у
    # Gar::Archive, но файлы — строки XML без zip. Записи — атрибуты XML (как в Sample);
    # таблица без записей файла не даёт.
    class MemoryArchive < Archive
      attr_reader :version_id

      # version — как в version.txt («2026.01.16»); root — имя таблицы → записи;
      # regions — код субъекта → имя таблицы → записи
      def initialize(version:, root:, regions:) # rubocop:disable Lint/MissingSuper -- файла архива нет
        @path       = "memory"
        @version_id = version.delete(".").to_i
        @entries    = {}
        @xml        = {}
        root.each { |name, records| add(nil, name, records) }
        regions.each { |code, tables| tables.each { |name, records| add(code, name, records) } }
      end

      def stream(item)
        entry = item.is_a?(Job) ? item.entry : item
        yield StringIO.new(@xml.fetch(entry.name))
      end

      private

      attr_reader :entries

      # Имя файла — как в выгрузке ФНС, чтобы его разобрал Archive::ENTRY_PATTERN
      def add(code, name, records)
        return if records.empty?

        table = Schema.fetch(name)
        file  = [code, "AS_#{table.file}_#{version_id}_memory.XML"].compact.join("/")
        @xml[file]     = "<ITEMS>#{records.map { |record| "<#{table.element} #{TestSupport.xml_attributes(record)}/>" }.join}</ITEMS>"
        @entries[file] = Entry.new(name: file, size: @xml[file].bytesize, compressed_size: nil, crc: nil, offset: nil, compression_method: nil)
      end
    end
  end
end
