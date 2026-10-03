# frozen_string_literal: true

require "date"
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
    # Комментарий частичного архива (Gar.download с субъектами): какие субъекты и таблицы в нём есть
    PARTIAL = /\Agar-partial regions=(?<regions>[\d,]*) tables=(?<tables>[a-z_,]*)\z/

    attr_reader :path

    # Archive из пути к zip; Archive (в том числе TestSupport::MemoryArchive) — как есть
    def self.open(source) = source.is_a?(Archive) ? source : new(source)

    # Файл таблицы по имени в архиве: [Schema::Table из tables, код субъекта или nil у
    # справочника]; nil — файл не нужен: чужая таблица или файл не на своём месте (справочник в
    # папке субъекта и наоборот)
    def self.table_file(name, tables)
      match  = ENTRY_PATTERN.match(name) or return
      table  = tables.find { _1.file == match[:file].upcase } or return
      region = match[:region]
      [table, region] if table.regional == !region.nil?
    end

    # Комментарий частичного архива с субъектами region_codes и таблицами субъекта из tables
    # (Schema::Table; справочники корня в нём всегда)
    def self.partial_comment(region_codes, tables)
      "gar-partial regions=#{region_codes.join(',')} tables=#{tables.select(&:regional).map(&:name).join(',')}"
    end

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

    # Дата выгрузки (Date) — из той же версии
    def version_date = Date.strptime(version_id.to_s, "%Y%m%d")

    # Работы импорта для таблиц (Schema::Table): справочники корня и таблицы субъектов —
    # всех или только region_codes. Крупные файлы первыми: так параллельный импорт не ждёт
    # в конце один большой файл. Частичный архив без нужных субъектов или таблиц — ImportError
    def jobs(tables, region_codes: nil)
      codes = Configuration.region_codes(region_codes)
      unless covers?(codes, tables)
        raise ImportError, "Архив #{File.basename(path)} частичный (субъекты #{partial[:regions].join(', ')}, таблицы " \
                           "#{partial[:tables].join(', ')}): в нём нет нужных данных — скачайте выгрузку с этими субъектами (Gar.download)"
      end

      jobs =
        entries.each_value.filter_map do |entry|
          file = self.class.table_file(entry.name, tables) or next
          table, region = file
          Job.new(table:, region_code: region, entry:) if region.nil? || codes.empty? || codes.include?(region)
        end
      jobs.sort_by { -_1.size }
    end

    # Субъекты и таблицы частичного архива: { regions: ["43", "11"], tables: [:houses, …] };
    # nil — архив полный
    def partial
      entries
      @partial
    end

    # Есть ли в архиве субъекты region_codes (пустой список — все) и таблицы tables (Schema::Table)
    def covers?(region_codes, tables)
      return true unless partial
      return false if region_codes.empty?

      (region_codes - partial[:regions]).empty? && (tables.select(&:regional).map(&:name) - partial[:tables]).empty?
    end

    # Поток данных файла (Entry или Job) прямо из zip
    def stream(item, &) = open_entry(item.is_a?(Job) ? item.entry : item, &)

    # Записи файла job — одной командой COPY в таблицу job.table схемы schema (pg_temp —
    # временную); filters — XmlReader. Возвращает число записей
    def copy(conn, job, schema, filters: {})
      reader = XmlReader.new(job.table, filters:, region_code: job.region_code)
      count  = 0
      conn.copy_data(job.table.copy_sql(schema)) { count = stream(job) { |io| reader.read(io) { conn.put_copy_data(_1) } } }
      count
    end

    private

    def open_entry(entry) = File.open(path, "rb") { |file| yield Stream.new(file, entry) }

    # Оглавление zip читается один раз: имя → Entry; заодно — комментарий частичного архива
    def entries
      @entries ||=
        begin
          Zip::File.open(path) do |zip|
            @partial =
              PARTIAL.match(zip.comment.to_s)&.then do |match|
                { regions: match[:regions].split(","), tables: match[:tables].split(",").map(&:to_sym) }
              end
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
