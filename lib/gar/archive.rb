# frozen_string_literal: true

require "zip"

module Gar
  # Архив ГАР (zip): версия выгрузки и выбор файлов таблиц без распаковки.
  #
  # Справочники лежат в корне архива, таблицы субъектов — в папках NN/ (код субъекта),
  # по одному файлу на таблицу: AS_<ТАБЛИЦА>_<дата>_<guid>.XML. Файл выбирается по точному
  # ключу таблицы, поэтому AS_HOUSES не захватывает AS_HOUSES_PARAMS. Дата в имени файла
  # не равна версии выгрузки: версия берётся из version.txt.
  class Archive
    # Работа импорта: файл одной таблицы одного субъекта (у справочника region_code — nil);
    # size — несжатый размер XML из оглавления zip
    Job =
      Data.define(:table, :region_code, :entry, :size) do
        def to_s = entry
      end

    VERSION_FILE  = "version.txt"
    ENTRY_PATTERN = %r{\A(?:(?<region>\d{2})/)?AS_(?<file>[A-Z_]+)_\d{8}_[^/]+\.xml\z}i

    attr_reader :path

    def initialize(path)
      raise ImportError, "Архив не найден: #{path}" unless File.file?(path)

      @path = path
    end

    # Версия выгрузки: «2026.01.16» из version.txt → 20260116
    def version_id
      @version_id ||=
        begin
          text = zip { |file| file.find_entry(VERSION_FILE)&.get_input_stream(&:read) }
          raise ImportError, "В архиве #{File.basename(path)} нет #{VERSION_FILE}: это не выгрузка ГАР" unless text

          date = text.match(/\A\W*(\d{4})\.(\d{2})\.(\d{2})/)
          raise ImportError, "Не удалось прочитать версию из #{VERSION_FILE}: #{text.lines.first.inspect}" unless date

          date.captures.join.to_i
        end
    end

    # Работы импорта для таблиц (Schema::Table): справочники корня и таблицы субъектов —
    # всех или только region_codes. Крупные файлы первыми: так параллельный импорт не ждёт
    # в конце один большой файл.
    def jobs(tables, region_codes: nil)
      by_file = tables.to_h { [_1.file, _1] }
      codes   = Array(region_codes).map(&:to_s)
      jobs    = entries.filter_map { |name, size| job_for(name, size, by_file, codes) }
      jobs.sort_by { -_1.size }
    end

    # Поток XML работы: читается прямо из zip, на диск ничего не распаковывается
    def open(job, &)
      zip { |file| file.get_entry(job.entry).get_input_stream(&) }
    end

    private

    # Работа для файла архива; nil — файл не нужен: чужая таблица, чужой субъект или файл
    # не на своём месте (справочник в папке субъекта и наоборот)
    def job_for(name, size, by_file, codes)
      match  = ENTRY_PATTERN.match(name) or return
      table  = by_file[match[:file].upcase] or return
      region = match[:region]
      return unless table.regional == !region.nil?
      return unless region.nil? || codes.empty? || codes.include?(region)

      Job.new(table: table.name, region_code: region, entry: name, size:)
    end

    def entries
      zip { |file| file.entries.map { [_1.name, _1.size] } }
    end

    def zip(&)
      Zip::File.open(path, &)
    rescue Zip::Error => e
      raise ImportError, "Не удалось прочитать архив #{File.basename(path)}: #{e.message}"
    end
  end
end
