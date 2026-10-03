# frozen_string_literal: true

module Gar
  class Downloader
    # Частичная загрузка полной выгрузки: справочники корня и файлы таблиц tables субъектов
    # region_codes — по HTTP Range прямо из zip на сервере, без скачивания архива целиком (два
    # субъекта набора :minimal — около 300 МБ вместо 50 ГБ). Результат — обычный zip с теми же
    # сжатыми данными и комментарием Archive.partial_comment: его читают Archive и rubyzip,
    # целостность каждого файла проверяет импорт (CRC32 из оглавления).
    #
    # Запросов немного: размер архива, хвост с концом оглавления, оглавление и по два на файл
    # (локальный заголовок и данные) — файловый сервер ФНС отвечает 503 на частые запросы.
    #
    # Обрыв не теряет скачанное: внутри запуска файл продолжается с места остановки, а после
    # перезапуска — тоже: раскладка нового zip однозначно задана оглавлением, поэтому по размеру
    # <архив>.part видно, какой файл и с какого байта докачивать. Рядом лежит <архив>.part.json —
    # адрес, размер архива на сервере и список файлов; не совпал (другая выгрузка или набор) —
    # загрузка начинается заново.
    module Partial
      LOCAL_HEADER   = 30
      CENTRAL_HEADER = 46
      EOCD           = 22
      # Больше этого — поле zip в 4 байта переполнено, размер и смещение пишутся в Zip64
      ZIP64_LIMIT    = 0xFFFFFFFF
      SIGNATURES     = { local: 0x04034b50, central: 0x02014b50, eocd: 0x06054b50, zip64_eocd: 0x06064b50, zip64_locator: 0x07064b50 }.freeze
      # Флаг zip «размеры и CRC — в дескрипторе после данных»: в своём заголовке они уже есть
      DATA_DESCRIPTOR = 0x0008

      # Файл в zip на сервере по центральному оглавлению
      Remote = Data.define(:name, :flags, :method, :time, :date, :crc, :compressed_size, :size, :offset)

      private

      # Собирает частичный архив в path и возвращает path; nil — сервер не отдаёт части файла
      # (тогда нужен полный архив)
      def download_partial(url, path, region_codes, tables, on_progress)
        uri  = URI(url)
        size = remote_size(uri) or return # без Range или размера — полный архив (download_mode)
        logger.info "Частичная загрузка #{url}: субъекты #{region_codes.join(', ')}"
        files = central_directory(uri, size).select { needed?(_1.name, region_codes, tables) }
        raise DownloadError, "В архиве #{url} нет файлов субъектов #{region_codes.join(', ')}" if files.none? { _1.name.include?("/") }

        write_partial("#{path}.part", uri, files, { url:, size:, files: files.map(&:name) }, Archive.partial_comment(region_codes, tables), on_progress)
        File.rename("#{path}.part", path)
        File.delete("#{path}.part.json")
        logger.info "Частичный архив: #{path} (#{files.size} файлов, #{Utils.format_size(File.size(path))})"
        path
      end

      # Справочник корня и version.txt — всегда, файл субъекта — если субъект и таблица нужны
      def needed?(name, region_codes, tables)
        return true unless name.include?("/")

        _, region = Archive.table_file(name, tables)
        region_codes.include?(region)
      end

      # Размер архива на сервере; nil — сервер не принимает Range или не сообщает размер
      def remote_size(uri)
        response = with_retries(uri.to_s) { http(uri) { check(_1.request(Net::HTTP::Head.new(uri))) } }
        raise DownloadError, "Архив #{uri} недоступен: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

        response.content_length if response["Accept-Ranges"] == "bytes"
      end

      # Байты from…to (включительно) файла на сервере
      def remote_bytes(uri, from, to)
        with_retries(uri.to_s) do
          request = Net::HTTP::Get.new(uri)
          request["Range"] = "bytes=#{from}-#{to}"
          response = http(uri) { check(_1.request(request)) }
          raise DownloadError, "Сервер вернул #{response.code} вместо части файла #{uri}" unless response.is_a?(Net::HTTPPartialContent)

          response.body.b
        end
      end

      # Центральное оглавление zip на сервере (обычный конец оглавления или Zip64)
      def central_directory(uri, size)
        tail   = remote_bytes(uri, [size - EOCD - 0xFFFF - 20, 0].max, size - 1)
        at     = tail.rindex([SIGNATURES[:eocd]].pack("V")) or raise DownloadError, "#{uri}: не найден конец оглавления zip"
        count, length, offset = tail.unpack("@#{at + 10}vVV")
        # Zip64 — заглушки в полях: число файлов 0xFFFF, размер или смещение оглавления 0xFFFFFFFF
        if count == 0xFFFF || [length, offset].include?(0xFFFFFFFF)
          locator = tail.unpack("@#{at - 20}VVQ<")
          raise DownloadError, "#{uri}: не найден указатель Zip64" unless locator[0] == SIGNATURES[:zip64_locator]

          # Запись Zip64: число файлов, размер и смещение оглавления — с 32-го байта
          count, length, offset = remote_bytes(uri, locator[2], locator[2] + 55).unpack("@32Q<Q<Q<")
        end
        parse_directory(remote_bytes(uri, offset, offset + length - 1), count)
      end

      def parse_directory(data, count)
        at = 0
        Array.new(count) do
          fields = data.unpack("@#{at}VvvvvvvVVVvvvvvVV")
          raise DownloadError, "Повреждено оглавление архива на сервере" unless fields[0] == SIGNATURES[:central]

          flags, method, time, date, crc, compressed, size, name_length, extra_length, comment_length = fields.values_at(3..12)
          offset = fields[16]
          name   = data.byteslice(at + CENTRAL_HEADER, name_length).force_encoding(Encoding::UTF_8)
          extra  = data.byteslice(at + CENTRAL_HEADER + name_length, extra_length)
          size, compressed, offset = zip64_values(extra, [size, compressed, offset])
          at += CENTRAL_HEADER + name_length + extra_length + comment_length
          Remote.new(name:, flags:, method:, time:, date:, crc:, compressed_size: compressed, size:, offset:)
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
          total  = files.sum(&:compressed_size)
          done   = 0
          offset = 0
          on_progress&.call(done, total, :download)
          written =
            files.map do |file|
              start  = offset
              offset = write_file(out, uri, file, start, ready) { on_progress&.call(done + _1, total, :download) }
              on_progress&.call(done += file.compressed_size, total, :download)
              [file, start]
            end
          out.seek(offset)
          out.truncate(offset)
          write_directory(out, written, comment)
        end
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

      # Сжатые данные файла с байта copied: начало — из его локального заголовка на сервере;
      # обрыв связи продолжает загрузку с места остановки. Блок получает число скачанных байт файла
      def copy_data(uri, file, out, copied)
        return if file.compressed_size == copied

        name_length, extra_length = remote_bytes(uri, file.offset, file.offset + LOCAL_HEADER - 1).unpack("@26vv")
        start = file.offset + LOCAL_HEADER + name_length + extra_length
        with_retries(uri.to_s, progress: -> { copied }) do
          request = Net::HTTP::Get.new(uri)
          request["Range"] = "bytes=#{start + copied}-#{start + file.compressed_size - 1}"
          http(uri) do |connection|
            connection.request(request) do |response|
              check(response)
              raise DownloadError, "Сервер вернул #{response.code} вместо части файла #{file.name}" unless response.is_a?(Net::HTTPPartialContent)

              response.read_body do |chunk|
                out.write(chunk)
                copied += chunk.bytesize
                yield copied
              end
            end
          end
          raise IOError, "#{file.name}: передача оборвалась на #{copied} байт из #{file.compressed_size}" if copied < file.compressed_size
        end
      end

      def local_header(file)
        zip64 = [file.size, file.compressed_size].any? { _1 >= ZIP64_LIMIT }
        extra = zip64 ? [1, 16, file.size, file.compressed_size].pack("vvQ<Q<") : "".b
        sizes = zip64 ? [0xFFFFFFFF, 0xFFFFFFFF] : [file.compressed_size, file.size]
        [SIGNATURES[:local], zip64 ? 45 : 20, file.flags & ~DATA_DESCRIPTOR, file.method, file.time, file.date, file.crc, *sizes,
         file.name.bytesize, extra.bytesize].pack("VvvvvvVVVvv") + file.name.b + extra
      end

      def write_directory(out, written, comment)
        start = out.pos
        written.each { |file, offset| out.write(central_header(file, offset)) }
        length = out.pos - start
        count  = written.size
        zip64  = count >= 0xFFFF || [start, length].any? { _1 >= ZIP64_LIMIT } || written.any? { |file, offset| zip64?(file, offset) }
        if zip64
          record = out.pos
          out.write([SIGNATURES[:zip64_eocd], 44, 45, 45, 0, 0, count, count, length, start].pack("VQ<vvVVQ<Q<Q<Q<"))
          out.write([SIGNATURES[:zip64_locator], 0, record, 1].pack("VVQ<V"))
          count = 0xFFFF
          length = 0xFFFFFFFF
          start = 0xFFFFFFFF
        end
        out.write([SIGNATURES[:eocd], 0, 0, count, count, length, start, comment.bytesize].pack("VvvvvVVv") + comment)
      end

      def central_header(file, offset)
        # Поля Zip64 — по порядку: размер, сжатый размер, смещение; в основных полях — 0xFFFFFFFF
        values = { size: file.size, compressed_size: file.compressed_size, offset: }
        large  = values.select { |_, value| value >= ZIP64_LIMIT }
        extra  = large.empty? ? "".b : [1, large.size * 8, *large.values].pack("vvQ<*")
        field  = ->(key) { large.key?(key) ? 0xFFFFFFFF : values[key] }
        [SIGNATURES[:central], 45, large.empty? ? 20 : 45, file.flags & ~DATA_DESCRIPTOR, file.method, file.time, file.date, file.crc,
         field.call(:compressed_size), field.call(:size), file.name.bytesize, extra.bytesize, 0, 0, 0, 0,
         field.call(:offset)].pack("VvvvvvvVVVvvvvvVV") + file.name.b + extra
      end

      def zip64?(file, offset) = [file.size, file.compressed_size, offset].any? { _1 >= ZIP64_LIMIT }
    end
  end
end
