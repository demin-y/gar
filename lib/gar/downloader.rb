# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "openssl"
require "fileutils"

module Gar
  # Сведения о выгрузках ГАР (API ФНС) и загрузка архивов.
  #
  # Архив качается в <имя>.zip.part и переименовывается только целиком, поэтому импорт
  # (Importer#find_latest_full_base_zip) никогда не берёт недокачанный файл. Обрыв связи
  # не теряет скачанное: следующая попытка (или следующий запуск) продолжает .part
  # запросом Range. Число попыток подряд без прогресса — api_retry_attempts.
  class Downloader
    include Loggable

    SECONDS_PER_DAY = 86_400
    PROGRESS_STEP   = 1 << 20
    NETWORK_ERRORS  = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT,
                       Errno::EHOSTUNREACH, SocketError, EOFError, IOError, OpenSSL::SSL::SSLError].freeze

    def all_versions
      get_json(Gar.configuration.api_all_versions_url)
    end

    def latest_version
      get_json(Gar.configuration.api_latest_version_url)
    end

    def version_info(version_id)
      all_versions.find { |v| v["VersionId"] == version_id } || raise(DownloadError, "Версия #{version_id} не найдена")
    end

    # Скачивает полную выгрузку в full_base_dir и возвращает путь к zip.
    # on_progress — ->(done, total, stage): байты, stage = :download; total — nil, если сервер
    # не сообщил размер
    def download_full_base(version_info, on_progress: nil)
      download(version_info["GarXMLFullURL"], Gar.configuration.full_base_dir, version_info["VersionId"], on_progress)
    end

    # Скачивает дельту в delta_dir; см. download_full_base
    def download_delta(version_info, on_progress: nil)
      download(version_info["GarXMLDeltaURL"], Gar.configuration.delta_dir, version_info["VersionId"], on_progress)
    end

    def cleanup_old_files(directory: nil, keep_days: 30, keep_versions: 5, dry_run: false)
      directory ||= Gar.configuration.full_base_dir
      return [] unless Dir.exist?(directory)

      log_cleanup_start(directory, keep_days, keep_versions, dry_run)

      zip_files = collect_zip_files(directory)
      return [] if zip_files.empty?

      files_to_delete = find_files_to_delete(zip_files, keep_days, keep_versions)

      if files_to_delete.empty?
        logger.info("Нет файлов для удаления")
        return []
      end

      report_files_to_delete(files_to_delete)

      if dry_run
        logger.info("Dry run завершен. Для реального удаления установите dry_run: false")
      else
        perform_deletion(files_to_delete)
      end

      files_to_delete.map { |f| f[:path] }
    end

    private

    def get_json(url)
      uri      = URI(url)
      response = with_retries(url) { http(uri) { _1.request(Net::HTTP::Get.new(uri)) } }
      raise DownloadError, "API ФНС вернул ошибку: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise DownloadError, "Ошибка разбора JSON ответа API ФНС: #{e.message}"
    end

    def download(url, target_dir, version_id, on_progress)
      raise DownloadError, "Нет ссылки на архив версии #{version_id}" if url.to_s.empty?

      path = File.join(target_dir, generate_filename(url, version_id))
      if File.exist?(path)
        logger.info "Архив уже скачан: #{path}"
        return path
      end

      FileUtils.mkdir_p(target_dir)
      part = "#{path}.part"
      logger.info "Скачивание #{url} в #{path}"
      with_retries(url, progress: -> { file_size(part) }) { fetch(URI(url), part, on_progress) }
      File.rename(part, path)
      logger.info "Файл скачан: #{path} (#{Utils.format_size(File.size(path))})"
      path
    end

    # Дописывает part с текущего размера; сервер без Range отдаёт файл заново (200). Если part
    # не совпадает с файлом на сервере (416, размеры разные), он удаляется и загрузка идёт с нуля
    def fetch(uri, part, on_progress)
      offset  = file_size(part)
      request = Net::HTTP::Get.new(uri)
      if offset.positive?
        request["Range"] = "bytes=#{offset}-"
        logger.info "Продолжение загрузки с #{Utils.format_size(offset)}"
      end

      restart = false
      http(uri) do |connection|
        connection.request(request) do |response|
          # 416: part уже содержит весь файл (обрыв пришёлся на самый конец) или чужой
          next restart = content_range_total(response) != offset if response.is_a?(Net::HTTPRangeNotSatisfiable)

          write_body(response, part, offset, on_progress)
        end
      end
      return unless restart

      logger.warn "Недокачанный файл не совпадает с архивом на сервере: загрузка начнётся заново"
      FileUtils.rm_f(part)
      fetch(uri, part, on_progress)
    end

    # Пишет ответ в part; прогресс — не чаще раза на PROGRESS_STEP байт и в конце
    def write_body(response, part, offset, on_progress)
      case response
      when Net::HTTPPartialContent then total = content_range_total(response)
      when Net::HTTPOK
        offset = 0
        total  = response.content_length
      else raise DownloadError, "Ошибка загрузки: #{response.code} #{response.message}"
      end

      reported = offset
      on_progress&.call(offset, total, :download)
      File.open(part, offset.zero? ? "wb" : "ab") do |file|
        response.read_body do |chunk|
          file.write(chunk)
          offset += chunk.bytesize
          next if offset - reported < PROGRESS_STEP

          reported = offset
          on_progress&.call(offset, total, :download)
        end
      end
      on_progress&.call(offset, total, :download) if reported != offset
      verify_size(offset, total)
    end

    def content_range_total(response)
      response["Content-Range"].to_s[%r{/(\d+)\z}, 1]&.to_i
    end

    def verify_size(size, total)
      return if total.nil? || size == total

      raise DownloadError, "Размер файла не совпадает с ожидаемым: #{Utils.format_size(size)} вместо #{Utils.format_size(total)}"
    end

    # Повторяет блок при сетевых ошибках: api_retry_attempts попыток подряд без прогресса
    # (progress — размер скачанного), между ними — пауза api_retry_timeout секунд
    def with_retries(url, progress: -> { 0 })
      config   = Gar.configuration
      failures = 0
      begin
        before = progress.call
        yield
      rescue *NETWORK_ERRORS => e
        failures = progress.call > before ? 1 : failures + 1
        raise DownloadError, "Не удалось скачать #{url} за #{failures} попыток: #{e.class}: #{e.message}" if failures >= config.api_retry_attempts

        logger.warn "Сетевая ошибка (#{e.class}: #{e.message}), повтор #{failures} через #{config.api_retry_timeout} с"
        sleep(config.api_retry_timeout)
        retry
      end
    end

    def http(uri, &)
      config  = Gar.configuration
      options = { use_ssl: uri.scheme == "https", read_timeout: config.api_read_timeout, open_timeout: config.api_read_timeout }
      unless config.api_ssl_verify
        logger.warn "Проверка SSL-сертификата отключена (api_ssl_verify = false)"
        options[:verify_mode] = OpenSSL::SSL::VERIFY_NONE
      end
      Net::HTTP.start(uri.host, uri.port, **options, &)
    end

    def file_size(path) = File.exist?(path) ? File.size(path) : 0

    def log_cleanup_start(directory, keep_days, keep_versions, dry_run)
      logger.info("Очистка старых файлов в: #{directory}")
      logger.info("  Сохраняем файлы не старше #{keep_days} дней")
      logger.info("  Сохраняем последние #{keep_versions} версий")
      logger.info("  Dry run: #{dry_run ? 'ВКЛЮЧЕН' : 'ОТКЛЮЧЕН'}")
    end

    def collect_zip_files(directory)
      Dir.glob(File.join(directory, "*.zip")).map do |path|
        {
          path:    path,
          mtime:   File.mtime(path),
          size:    File.size(path),
          version: extract_version_from_filename(path)
        }
      end
    end

    def find_files_to_delete(zip_files, keep_days, keep_versions) # rubocop:disable Metrics/PerceivedComplexity
      files_to_delete = []

      files_by_version = zip_files.group_by { |f| f[:version] }.sort_by { |version, _| version || 0 }.reverse

      files_by_version.each_with_index do |(_version, files), index|
        if index >= keep_versions
          files_to_delete.concat(files)
        else
          sorted_files = files.sort_by { |f| f[:mtime] }.reverse
          files_to_delete.concat(sorted_files.drop(1))
        end
      end

      cutoff_time = Time.now - (keep_days * SECONDS_PER_DAY)
      old_files = zip_files.select { |f| f[:mtime] < cutoff_time }
      files_to_delete.concat(old_files)

      files_to_delete.uniq
    end

    def report_files_to_delete(files_to_delete)
      total_size = files_to_delete.sum { |f| f[:size] }

      logger.info("Найдено #{files_to_delete.length} файлов для удаления:")
      files_to_delete.each do |file|
        age_days = ((Time.now - file[:mtime]) / SECONDS_PER_DAY).round(1)
        logger.info("  #{File.basename(file[:path])} (#{Utils.format_size(file[:size])}, #{age_days} дней)")
      end
      logger.info("Общий размер для освобождения: #{Utils.format_size(total_size)}")
    end

    def perform_deletion(files_to_delete)
      logger.info("Выполняем удаление...")

      deleted_count = 0
      deleted_size  = 0

      files_to_delete.each do |file|
        File.delete(file[:path])
        deleted_count += 1
        deleted_size += file[:size]
        logger.debug "Удален: #{File.basename(file[:path])}"
      rescue StandardError => e
        logger.error "Ошибка удаления #{File.basename(file[:path])}: #{e.message}"
      end

      logger.info("Удалено #{deleted_count} файлов, освобождено #{Utils.format_size(deleted_size)}")
    end

    def generate_filename(url, version_id)
      base = URI.parse(url).path.split("/").last.gsub(/[^a-zA-Z0-9._-]/, "_")
      base.sub(/\.zip$/, "_v#{version_id}.zip")
    end

    def extract_version_from_filename(filepath) = File.basename(filepath)[/_v(\d+)\.zip\z/, 1]&.to_i
  end
end
