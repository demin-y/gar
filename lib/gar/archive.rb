# frozen_string_literal: true

require "zip"
require "zlib"

module Gar
  # Архив ГАР (zip): версия выгрузки и выбор файлов таблиц без распаковки.
  #
  # Справочники лежат в корне архива, таблицы субъектов — в папках NN/ (код субъекта),
  # по одному файлу на таблицу: AS_<ТАБЛИЦА>_<дата>_<guid>.XML. Файл выбирается по точному
  # ключу таблицы, поэтому AS_HOUSES не захватывает AS_HOUSES_PARAMS. Дата в имени файла
  # не равна версии выгрузки: версия берётся из version.txt.
  #
  # Оглавление читает rubyzip, а данные файла — Archive::Stream: потоком с диска, в постоянной
  # памяти, без распаковки на диск.
  class Archive
    # Файл в zip по оглавлению: несжатый и сжатый размер, CRC32, смещение локального заголовка
    Entry = Data.define(:name, :size, :compressed_size, :crc, :offset, :compression_method)

    # Работа импорта: файл одной таблицы (Schema::Table) одного субъекта; у справочника
    # region_code — nil
    Job =
      Data.define(:table, :region_code, :entry) do
        def size = entry.size
        def to_s = entry.name
      end

    # Распакованные данные файла для Ox (readpartial). Сжатые данные читаются с диска кусками
    # и распаковываются Zlib в переиспользуемые буферы, поэтому память процесса не зависит от
    # размера файла: поток rubyzip на каждое чтение создаёт новые строки, и до сборки мусора
    # их копится на десятки мегабайт. В конце размер и CRC32 сверяются с оглавлением.
    class Stream
      CHUNK = 1 << 16

      def initialize(file, entry)
        unless [Zip::Entry::STORED, Zip::Entry::DEFLATED].include?(entry.compression_method)
          raise ImportError, "#{entry.name}: метод сжатия #{entry.compression_method} не поддерживается"
        end

        @file     = file
        @entry    = entry
        @left     = entry.compressed_size
        @inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS) if entry.compression_method == Zip::Entry::DEFLATED
        @input    = String.new(capacity: CHUNK)
        @output   = String.new(capacity: CHUNK * 8)
        @position = 0
        @size     = 0
        @crc      = Zlib.crc32
        seek_to_data
      end

      def readpartial(length, _buffer = nil)
        fill while @position >= @output.bytesize
        part = @output.byteslice(@position, length)
        @position += part.bytesize
        part
      end

      # Остаток файла целиком — для маленьких файлов (version.txt)
      def read
        data = "".b
        loop { data << readpartial(CHUNK) }
      rescue EOFError
        data
      end

      private

      # Данные начинаются после локального заголовка: 30 байт, имя и дополнительное поле
      def seek_to_data
        @file.seek(@entry.offset)
        header = @file.read(Zip::LOCAL_ENTRY_STATIC_HEADER_LENGTH)
        raise ImportError, "#{@entry.name}: не найден заголовок файла в архиве" unless header&.unpack1("V") == Zip::LOCAL_ENTRY_SIGNATURE

        name_length, extra_length = header.unpack("@26vv")
        @file.seek(name_length + extra_length, IO::SEEK_CUR)
      end

      def fill
        if @left.zero?
          verify
          raise EOFError
        end
        raise ImportError, "#{@entry.name}: архив обрезан" unless @file.read([@left, CHUNK].min, @input)

        @left -= @input.bytesize
        @inflater ? @inflater.inflate(@input, buffer: @output) : @output.replace(@input)
        @size    += @output.bytesize
        @crc      = Zlib.crc32(@output, @crc)
        @position = 0
      rescue Zlib::Error => e
        raise corrupted(e.message)
      end

      # Inflate#finish не вызываем: после inflate(buffer:) он роняет процесс (zlib 3.1).
      # Весь вывод уже получен из inflate, конец потока проверяет finished?
      def verify
        return if @verified

        complete = @inflater.nil? || @inflater.finished?
        @inflater&.close
        @verified = true
        raise corrupted("размер или CRC32 не совпадают с оглавлением") unless complete && @size == @entry.size && @crc == @entry.crc
      end

      def corrupted(reason) = ImportError.new("#{@entry.name}: файл в архиве повреждён (#{reason})")
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
          entry = entries[VERSION_FILE]
          raise ImportError, "В архиве #{File.basename(path)} нет #{VERSION_FILE}: это не выгрузка ГАР" unless entry

          text = stream(entry, &:read).force_encoding(Encoding::UTF_8)
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
      jobs    = entries.each_value.filter_map { |entry| job_for(entry, by_file, codes) }
      jobs.sort_by { -_1.size }
    end

    # Поток данных файла (Entry или Job) прямо из zip
    def stream(item)
      entry = item.is_a?(Job) ? item.entry : item
      File.open(path, "rb") { |file| yield Stream.new(file, entry) }
    end

    private

    # Работа для файла архива; nil — файл не нужен: чужая таблица, чужой субъект или файл
    # не на своём месте (справочник в папке субъекта и наоборот)
    def job_for(entry, by_file, codes)
      match  = ENTRY_PATTERN.match(entry.name) or return
      table  = by_file[match[:file].upcase] or return
      region = match[:region]
      return unless table.regional == !region.nil?
      return unless region.nil? || codes.empty? || codes.include?(region)

      Job.new(table:, region_code: region, entry:)
    end

    # Оглавление zip читается один раз: имя → Entry
    def entries
      @entries ||=
        begin
          Zip::File.open(path) do |zip|
            zip.entries.to_h do |entry|
              [entry.name, Entry.new(name: entry.name, size: entry.size, compressed_size: entry.compressed_size, crc: entry.crc,
                                     offset: entry.local_header_offset, compression_method: entry.compression_method)]
            end
          end
        rescue Zip::Error => e
          raise ImportError, "Не удалось прочитать архив #{File.basename(path)}: #{e.message}"
        end
    end
  end
end
