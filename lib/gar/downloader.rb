# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "openssl"
require "fileutils"

module Gar
  class Downloader
    include Loggable

    SECONDS_PER_DAY = 86_400
    DownloadContext = Struct.new(:http, :uri, :destination_path, :total_size, :show_progress, keyword_init: true)

    def all_versions
      api_get(Gar.configuration.api_all_versions_url)
    end

    def latest_version
      api_get(Gar.configuration.api_latest_version_url)
    end

    def version_info(version_id)
      versions = all_versions
      versions.find { |v| v["VersionId"] == version_id } || raise(Error, "Версия #{version_id} не найдена")
    end

    def download_full_base(version_info, show_progress: false)
      url        = version_info["GarXMLFullURL"]
      version_id = version_info["VersionId"]
      download(url, Gar.configuration.full_base_dir, version_id: version_id, show_progress: show_progress)
    end

    def download_delta(version_info, show_progress: false)
      url        = version_info["GarXMLDeltaURL"]
      version_id = version_info["VersionId"]
      download(url, Gar.configuration.delta_dir, version_id: version_id, show_progress: show_progress)
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

    # API методы

    def api_get(url)
      options = {}

      unless Gar.configuration.api_ssl_verify
        options[:verify] = false
        logger.warn("SSL верификация отключена для API запросов")
      end

      response = HTTParty.get(url, options)

      raise DownloadError, "API вернул ошибку: #{response.code} #{response.message}" unless response.success?

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise DownloadError, "Ошибка парсинга JSON ответа: #{e.message}"
    end

    # Загрузка файлов

    def download(url, target_dir, version_id: nil, show_progress: false)
      FileUtils.mkdir_p(target_dir)

      filename = generate_filename(url, version_id)
      zip_path = File.join(target_dir, filename)

      logger.info("Скачивание в: #{zip_path}")

      download_file(url, zip_path, show_progress: show_progress)

      logger.info("Файл скачан: #{zip_path} (#{format_bytes(File.size(zip_path))})")

      zip_path
    end

    # rubocop:disable-next Metrics/PerceivedComplexity
    def download_file(url, destination_path, show_progress: false)
      max_attempts  = Gar.configuration.api_retry_attempts
      retry_timeout = Gar.configuration.api_retry_timeout

      attempt       = 0
      last_error    = nil
      made_progress = false

      while attempt < max_attempts
        attempt += 1

        begin
          existing_size = File.exist?(destination_path) ? File.size(destination_path) : 0
          resume_download = existing_size.positive?

          log_resume_start(existing_size) if resume_download && attempt == 1

          downloaded_size = perform_download(url, destination_path, resume_download, existing_size, show_progress)

          if downloaded_size > existing_size
            attempt = 0
            made_progress = true
          end

          log_resume_complete(downloaded_size, existing_size) if resume_download && existing_size.positive?

          return
        rescue Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET, Errno::ETIMEDOUT, SocketError => e
          last_error = e

          if made_progress
            attempt = 0
            made_progress = false
            logger.warn("После успешного прогресса возникла ошибка: #{e.message}. Сбрасываем счетчик и повторяем...")
          elsif attempt < max_attempts
            logger.warn("Попытка #{attempt} неудачна: #{e.message}. Повтор через #{retry_timeout} сек...")
            sleep(retry_timeout)
          else
            logger.error("Все #{max_attempts} попыток загрузки неудачны")
            raise last_error
          end
        end
      end

      raise last_error if last_error
    end

    def perform_download(url, destination_path, resume_download, existing_size, show_progress)
      uri  = URI.parse(url)
      http = setup_http(uri)

      total_size = fetch_content_length(http, uri)
      ctx = DownloadContext.new(
        http: http, uri: uri, destination_path: destination_path,
        total_size: total_size, show_progress: show_progress
      )

      if resume_download
        download_with_resume(ctx, existing_size)
      else
        download_from_start(ctx)
      end
    end

    def download_with_resume(ctx, existing_size)
      request = Net::HTTP::Get.new(ctx.uri.request_uri)
      request["Range"] = "bytes=#{existing_size}-"

      downloaded_size = existing_size

      ctx.http.request(request) do |response|
        if response.code == "200"
          logger.info("Сервер не поддерживает возобновление загрузки, начинаем заново...")
          FileUtils.rm_f(ctx.destination_path)
          return download_from_start(ctx)
        end

        validate_partial_response(response)

        File.open(ctx.destination_path, "ab") do |file|
          response.read_body do |chunk|
            file.write(chunk)
            downloaded_size += chunk.bytesize
            show_download_progress(downloaded_size, ctx.total_size) if ctx.show_progress
          end
        end
      end

      finalize_download(ctx, downloaded_size)
    end

    def download_from_start(ctx)
      request = Net::HTTP::Get.new(ctx.uri.request_uri)
      downloaded_size = 0

      ctx.http.request(request) do |response|
        validate_success_response(response)

        File.open(ctx.destination_path, "wb") do |file|
          response.read_body do |chunk|
            file.write(chunk)
            downloaded_size += chunk.bytesize
            show_download_progress(downloaded_size, ctx.total_size) if ctx.show_progress
          end
        end
      end

      finalize_download(ctx, downloaded_size)
    end

    def finalize_download(ctx, downloaded_size)
      print "\n" if ctx.show_progress
      validate_download_size(ctx.destination_path, ctx.total_size)
      downloaded_size
    end

    def validate_partial_response(response)
      return if response.code == "206"

      raise DownloadError, "Неожиданный ответ сервера при возобновлении: #{response.code}"
    end

    def validate_success_response(response)
      return if response.code == "200"

      raise DownloadError, "Ошибка загрузки: #{response.code} #{response.message}"
    end

    def validate_download_size(destination_path, expected_size)
      return unless expected_size

      actual_size = File.size(destination_path)
      return if actual_size == expected_size

      raise DownloadError,
            "Размер файла не соответствует ожидаемому: #{format_bytes(actual_size)} вместо #{format_bytes(expected_size)}"
    end

    # HTTP helpers

    def setup_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.read_timeout = Gar.configuration.api_read_timeout

      if http.use_ssl?
        if Gar.configuration.api_ssl_verify
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        else
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          logger.warn("SSL верификация отключена (api_ssl_verify: false)")
        end
      end

      http
    end

    def fetch_content_length(http, uri)
      head_request  = Net::HTTP::Head.new(uri.request_uri)
      head_response = http.request(head_request)
      head_response["content-length"]&.to_i
    end

    def log_resume_start(existing_size)
      logger.info("Найден частично скачанный файл (#{format_bytes(existing_size)}), возобновляем загрузку...")
    end

    def log_resume_complete(downloaded_size, existing_size)
      logger.info("Загрузка возобновлена: +#{format_bytes(downloaded_size - existing_size)}")
    end

    def show_download_progress(downloaded_size, total_size)
      return unless total_size&.positive?

      progress = (downloaded_size.to_f / total_size * 100).round(1)
      print "\rПрогресс: #{progress}% (#{format_bytes(downloaded_size)} / #{format_bytes(total_size)})"
    end

    # Cleanup helpers

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
        logger.info("  #{File.basename(file[:path])} (#{format_bytes(file[:size])}, #{age_days} дней)")
      end
      logger.info("Общий размер для освобождения: #{format_bytes(total_size)}")
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

      logger.info("Удалено #{deleted_count} файлов, освобождено #{format_bytes(deleted_size)}")
    end

    # Utilities

    def format_bytes(bytes)
      return "0 B" if bytes.nil? || bytes.zero?

      units = ["B", "KB", "MB", "GB"]
      exp = (Math.log(bytes) / Math.log(1024)).to_i
      exp = [exp, units.size - 1].min
      "#{(bytes / (1024.0**exp)).round(1)} #{units[exp]}"
    end

    def generate_filename(url, version_id)
      base = URI.parse(url).path.split("/").last.gsub(/[^a-zA-Z0-9._-]/, "_")
      base.sub(/\.zip$/, "_v#{version_id}.zip")
    end

    def extract_version_from_filename(filepath)
      filename = File.basename(filepath)
      match = filename.match(/_v(\d+)\.zip$/)
      match ? match[1].to_i : nil
    end
  end
end
