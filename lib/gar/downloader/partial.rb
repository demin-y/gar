# frozen_string_literal: true

require "zip"

module Gar
  class Downloader
    # Частичная загрузка полной выгрузки: справочники корня и файлы таблиц tables субъектов
    # region_codes — по HTTP Range прямо из zip на сервере, без скачивания архива целиком (два
    # субъекта набора :minimal — около 300 МБ вместо 50 ГБ). Результат — обычный zip с теми же
    # сжатыми данными и комментарием Archive.partial_comment: его читают Archive и rubyzip,
    # целостность каждого файла проверяет импорт (CRC32 из оглавления).
    #
    # Запросов немного и по одному соединению (файловый сервер ФНС отвечает 503 на частые
    # запросы): размер архива, хвост с концом оглавления, оглавление и по одному на файл —
    # локальный заголовок и сжатые данные до следующего файла архива.
    #
    # Обрыв не теряет скачанное: внутри запуска файл продолжается с места остановки, а после
    # перезапуска — тоже: раскладка нового zip однозначно задана оглавлением, поэтому по размеру
    # <архив>.part видно, какой файл и с какого байта докачивать. Рядом лежит <архив>.part.json —
    # адрес, размер архива на сервере и список файлов; не совпал (другая выгрузка или набор) —
    # загрузка начинается заново.
    module Partial
      LOCAL_HEADER   = Zip::LOCAL_ENTRY_STATIC_HEADER_LENGTH
      CENTRAL_HEADER = Zip::CDIR_ENTRY_STATIC_HEADER_LENGTH
      EOCD           = 22
      # Концы оглавления: обычный, запись и указатель Zip64
      EOCD_SIGNATURE          = 0x06054b50
      ZIP64_EOCD_SIGNATURE    = 0x06064b50
      ZIP64_LOCATOR_SIGNATURE = 0x07064b50
      # Больше этого — поле zip в 4 байта переполнено, размер и смещение пишутся в Zip64
      ZIP64_LIMIT = 0xFFFFFFFF
      # Флаг zip «размеры и CRC — в дескрипторе после данных»: в своём заголовке они уже есть
      DATA_DESCRIPTOR = 0x0008

      # Файл в zip на сервере по центральному оглавлению; finish — последний байт его области на
      # сервере (до следующего файла или оглавления: данные и, возможно, дескриптор)
      Remote = Data.define(:name, :flags, :method, :time, :date, :crc, :compressed_size, :size, :offset, :finish)

      private

      # Собирает частичный архив в path и возвращает path; nil — сервер не отдаёт части файла
      # или не сообщает размер (тогда — по download_mode)
      def download_partial(url, path, region_codes, tables, on_progress)
        uri  = URI(url)
        size = remote_size(uri) or return
        logger.info "Частичная загрузка #{url}: субъекты #{region_codes.join(', ')}"
        files = central_directory(uri, size).select { needed?(_1.name, region_codes, tables) }
        raise DownloadError, "В архиве #{url} нет файлов субъектов #{region_codes.join(', ')}" if files.none? { _1.name.include?("/") }

        part = "#{path}.part"
        write_partial(part, uri, files, { url:, size:, files: files.map(&:name) }, Archive.partial_comment(region_codes, tables), on_progress)
        File.rename(part, path)
        File.delete("#{part}.json")
        logger.info "Частичный архив: #{path} (#{files.size} файлов, #{Utils.format_size(File.size(path))})"
        path
      ensure
        close_session
      end

      # Справочник корня и version.txt — всегда, файл субъекта — если субъект и таблица нужны
      def needed?(name, region_codes, tables)
        return true unless name.include?("/")

        _, region = Archive.table_file(name, tables)
        region_codes.include?(region)
      end

      # Соединение с сервером архива на всю загрузку (keep-alive); после ошибки — новое
      def session(uri) = @session ||= http(uri)

      def close_session
        @session&.finish if @session&.started?
      rescue IOError
        nil
      ensure
        @session = nil
      end

      # Запрос request по соединению загрузки: блок получает ответ, ошибка закрывает соединение
      # (непрочитанный ответ оставил бы его в неопределённом состоянии)
      def remote(uri, request, &)
        session(uri).request(request) { |response| yield check(response) }
      rescue StandardError
        close_session
        raise
      end

      # Размер архива на сервере; nil — сервер не принимает Range или не сообщает размер
      def remote_size(uri)
        response = with_retries(uri.to_s) { remote(uri, Net::HTTP::Head.new(uri)) { _1 } }
        raise DownloadError, "Архив #{uri} недоступен: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

        response.content_length if response["Accept-Ranges"] == "bytes"
      end

      # Байты from…to (включительно) файла на сервере — куски блоку
      def remote_range(uri, from, to, &)
        request = Net::HTTP::Get.new(uri)
        request["Range"] = "bytes=#{from}-#{to}"
        remote(uri, request) do |response|
          raise DownloadError, "Сервер вернул #{response.code} вместо части файла #{uri}" unless response.is_a?(Net::HTTPPartialContent)

          response.read_body(&)
        end
      end

      # Байты from…to (включительно) файла на сервере строкой
      def remote_bytes(uri, from, to)
        with_retries(uri.to_s) do
          data = "".b
          remote_range(uri, from, to) { data << _1 }
          data
        end
      end

      # Центральное оглавление zip на сервере (обычный конец оглавления или Zip64); у файлов —
      # конец их области (начало следующего файла или оглавления)
      def central_directory(uri, size)
        tail_start = [size - EOCD - 0xFFFF - 20 - 56, 0].max
        tail = remote_bytes(uri, tail_start, size - 1)
        at   = tail.rindex([EOCD_SIGNATURE].pack("V")) or raise DownloadError, "#{uri}: не найден конец оглавления zip"
        count, length, offset = tail.unpack("@#{at + 10}vVV")
        # Zip64 — заглушки в полях: число файлов 0xFFFF, размер или смещение оглавления 0xFFFFFFFF
        if count == 0xFFFF || [length, offset].include?(0xFFFFFFFF)
          locator = tail.unpack("@#{at - 20}VVQ<")
          raise DownloadError, "#{uri}: не найден указатель Zip64" unless locator[0] == ZIP64_LOCATOR_SIGNATURE

          # Запись Zip64 (обычно уже в хвосте): число файлов, размер и смещение оглавления — с 32-го байта
          record = locator[2] >= tail_start ? tail.byteslice(locator[2] - tail_start, 56) : remote_bytes(uri, locator[2], locator[2] + 55)
          count, length, offset = record.unpack("@32Q<Q<Q<")
        end
        files = parse_directory(remote_bytes(uri, offset, offset + length - 1), count).sort_by(&:offset)
        files.each_cons(2).map { |file, after| file.with(finish: after.offset - 1) } << files.last.with(finish: offset - 1)
      end

      def parse_directory(data, count)
        at = 0
        Array.new(count) do
          fields = data.unpack("@#{at}VvvvvvvVVVvvvvvVV")
          raise DownloadError, "Повреждено оглавление архива на сервере" unless fields[0] == Zip::CENTRAL_DIRECTORY_ENTRY_SIGNATURE

          flags, method, time, date, crc, compressed, size, name_length, extra_length, comment_length = fields.values_at(3..12)
          name  = data.byteslice(at + CENTRAL_HEADER, name_length).force_encoding(Encoding::UTF_8)
          extra = data.byteslice(at + CENTRAL_HEADER + name_length, extra_length)
          size, compressed, offset = zip64_values(extra, [size, compressed, fields[16]])
          at += CENTRAL_HEADER + name_length + extra_length + comment_length
          Remote.new(name:, flags:, method:, time:, date:, crc:, compressed_size: compressed, size:, offset:, finish: nil)
        end
      end

      # Значения из дополнительного поля Zip64 (id 1) — по порядку для полей, равных 0xFFFFFFFF
      def zip64_values(extra, values)
        at = 0
        while at + 4 <= extra.bytesize
          id, length = extra.unpack("@#{at}vv")
          if id == 1
            stored = extra.byteslice(at + 4, length).unpack("Q<*")
            return values.map { _1 == 0xFFFFFFFF ? stored.shift : _1 }
          end
          at += 4 + length
        end
        values
      end

      # Пишет zip: для каждого файла — свой локальный заголовок и сжатые данные с сервера, затем
      # оглавление и конец оглавления (Zip64, если нужно). source — откуда и что качается:
      # совпадает с сохранённым в <part>.json — докачка с конца <part>
      def write_partial(part, uri, files, source, comment, on_progress) # rubocop:disable Metrics/ParameterLists
        resume = resumable?(part, source)
        File.write("#{part}.json", JSON.generate(source)) unless resume
        File.open(part, resume ? "r+b" : "wb") do |out|
          ready = out.size
          logger.info "Продолжение частичной загрузки с #{Utils.format_size(ready)}" if ready.positive?
          progress = progress_reporter(files.sum(&:compressed_size), on_progress)
          done     = 0
          offset   = 0
          written =
            files.map do |file|
              start  = offset
              offset = write_file(out, uri, file, start, ready) { progress.call(done + _1) }
              progress.call(done += file.compressed_size)
              [file, start]
            end
          out.seek(offset)
          out.truncate(offset)
          write_directory(out, written, comment)
        end
      end

      # Прогресс загрузки для on_progress — не чаще раза на PROGRESS_STEP байт, начало и конец всегда
      def progress_reporter(total, on_progress)
        reported = nil
        report   =
          lambda do |done|
            next if reported && done - reported < PROGRESS_STEP && done != total

            reported = done
            on_progress&.call(done, total, :download)
          end
        report.call(0)
        report
      end

      # Файл с позиции offset: заголовок и данные, кроме уже записанных до ready (докачка).
      # Блок получает число скачанных байт файла; возвращает позицию за файлом
      def write_file(out, uri, file, offset, ready, &)
        header = local_header(file)
        data   = offset + header.bytesize
        finish = data + file.compressed_size
        return finish if ready >= finish # файл уже скачан целиком

        copied = (ready - data).clamp(0, file.compressed_size)
        out.seek(copied.positive? ? data + copied : offset)
        out.write(header) unless copied.positive?
        copy_data(uri, file, out, copied, &)
        finish
      end

      def resumable?(part, source)
        File.exist?(part) && File.exist?("#{part}.json") && JSON.parse(File.read("#{part}.json"), symbolize_names: true) == source
      rescue JSON::ParserError
        false
      end

      # Сжатые данные файла с байта copied. Начало файла — одним запросом с его локальным
      # заголовком (из него — где начинаются данные); продолжение после обрыва — с места
      # остановки (заголовок — отдельным запросом, только если начало ещё не известно). Блок
      # получает число скачанных байт файла
      def copy_data(uri, file, out, copied)
        return if file.compressed_size == copied

        start = data_start(remote_bytes(uri, file.offset, file.offset + LOCAL_HEADER - 1), file) if copied.positive?
        with_retries(uri.to_s, progress: -> { copied }) do
          header = "".b
          remote_range(uri, start ? start + copied : file.offset, file.finish) do |chunk|
            unless start
              chunk = after_header(header, chunk, file) or next
              start = data_start(header, file)
            end
            next if copied >= file.compressed_size # за данными — дескриптор и т. п.

            data = chunk.byteslice(0, file.compressed_size - copied)
            out.write(data)
            yield copied += data.bytesize
          end
          raise IOError, "#{file.name}: передача оборвалась на #{copied} байт из #{file.compressed_size}" if copied < file.compressed_size
        end
      end

      # Начало сжатых данных файла по его локальному заголовку (первые байты заголовка)
      def data_start(header, file) = file.offset + LOCAL_HEADER + header.unpack("@26vv").sum

      # Поток с начала локального заголовка: копит заголовок в header; когда он прочитан целиком —
      # возвращает байты после него, до того — nil
      def after_header(header, chunk, file)
        header << chunk
        return if header.bytesize < LOCAL_HEADER || header.bytesize < data_start(header, file) - file.offset

        header.byteslice((data_start(header, file) - file.offset)..)
      end

      # Поля Zip64 файла: переполненные размер, сжатый размер и смещение — по порядку zip
      def zip64_fields(file, offset = 0)
        { size: file.size, compressed_size: file.compressed_size, offset: }.select { |_, value| value >= ZIP64_LIMIT }
      end

      # Локальный заголовок: если переполнен любой размер, оба — в поле Zip64
      def local_header(file)
        zip64 = zip64_fields(file).any?
        extra = zip64 ? [1, 16, file.size, file.compressed_size].pack("vvQ<Q<") : "".b
        sizes = zip64 ? [0xFFFFFFFF, 0xFFFFFFFF] : [file.compressed_size, file.size]
        [Zip::LOCAL_ENTRY_SIGNATURE, zip64 ? 45 : 20, file.flags & ~DATA_DESCRIPTOR, file.method, file.time, file.date, file.crc, *sizes,
         file.name.bytesize, extra.bytesize].pack("VvvvvvVVVvv") + file.name.b + extra
      end

      # Запись оглавления: переполненные поля — 0xFFFFFFFF, их значения — в поле Zip64
      def central_header(file, offset)
        large = zip64_fields(file, offset)
        extra = large.empty? ? "".b : [1, large.size * 8, *large.values].pack("vvQ<*")
        field = ->(key, value) { large.key?(key) ? 0xFFFFFFFF : value }
        [Zip::CENTRAL_DIRECTORY_ENTRY_SIGNATURE, 45, large.empty? ? 20 : 45, file.flags & ~DATA_DESCRIPTOR, file.method, file.time, file.date,
         file.crc, field.call(:compressed_size, file.compressed_size), field.call(:size, file.size), file.name.bytesize, extra.bytesize, 0, 0, 0, 0,
         field.call(:offset, offset)].pack("VvvvvvvVVVvvvvvVV") + file.name.b + extra
      end

      # Оглавление и его конец; Zip64-конец — если переполнены число файлов, размер или начало
      # оглавления (переполненные поля файлов — в их записях)
      def write_directory(out, written, comment)
        start = out.pos
        written.each { |file, offset| out.write(central_header(file, offset)) }
        length = out.pos - start
        count  = written.size
        if count >= 0xFFFF || [start, length].any? { _1 >= ZIP64_LIMIT }
          record = out.pos
          out.write([ZIP64_EOCD_SIGNATURE, 44, 45, 45, 0, 0, count, count, length, start].pack("VQ<vvVVQ<Q<Q<Q<"))
          out.write([ZIP64_LOCATOR_SIGNATURE, 0, record, 1].pack("VVQ<V"))
          count = 0xFFFF
          length = 0xFFFFFFFF
          start = 0xFFFFFFFF
        end
        out.write([EOCD_SIGNATURE, 0, 0, count, count, length, start, comment.bytesize].pack("VvvvvVVv") + comment)
      end
    end
  end
end
