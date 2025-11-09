# frozen_string_literal: true

require "zip"
require "fileutils"
require "parallel"
require_relative "xml_parser"
require_relative "entities/entities"
require_relative "full_path_builder"

module Gar
  class Importer
    include Loggable

    COPY_ESCAPE_REGEX = /[\\\t\n\r]/
    COPY_ESCAPE_CHARS = { "\\" => "\\\\", "\t" => "\\t", "\n" => "\\n", "\r" => "\\r" }.freeze

    attr_reader :db

    def initialize(db_conn = nil)
      @db = Gar::Database.new(db_conn)
      log_connection_info("Инициализировано соединение")
    end

    def db_conn
      db.conn
    end

    def import_full_base(zip_path)
      version_id = extract_version_from_archive(zip_path)
      logger.info "Начинаем импорт полной базы данных GAR версии #{version_id}"

      schema_name = "gar_v#{version_id}"

      drop_schema(schema_name)
      create_schema(schema_name)
      create_tables(schema_name)
      logger.info "Создана схема #{schema_name} с таблицами"

      save_version_info(schema_name, version_id)
      logger.info "Информация о версии сохранена"

      logger.info "Импорт данных в схему #{schema_name}..."
      import_tables(zip_path, schema_name)
      logger.info "Импорт завершен успешно! Новая схема: #{schema_name}"

      schema_name
    rescue StandardError => e
      logger.error "Ошибка импорта: #{e.message}"
      logger.error "Схема #{schema_name} оставлена для анализа. Удалите вручную: DROP SCHEMA #{schema_name} CASCADE"
      raise e
    end

    def find_latest_full_base_zip(directory: nil)
      target_dir = directory || Gar.configuration.full_base_dir
      return nil unless Dir.exist?(target_dir)

      Dir.glob(File.join(target_dir, "*.zip")).max_by { |f| File.mtime(f) }
    end

    def switch_to_imported_schema(new_schema_name)
      raise ArgumentError, "Имя новой схемы не может быть пустым" if new_schema_name.empty?
      raise ArgumentError, "Схема #{new_schema_name} не существует" unless schema_exists?(new_schema_name)

      current_schema = Gar.configuration.database_schema
      return logger.info "Новая схема уже является текущей" if new_schema_name == current_schema

      backup_current_schema(current_schema)

      logger.info "Переименование схемы #{new_schema_name} в #{current_schema}..."
      rename_schema(new_schema_name, current_schema)
      logger.info "Новая схема установлена как текущая: #{current_schema}"
    end

    def extract_version_from_archive(zip_path)
      File.basename(zip_path)[/_v(\d+)\.zip$/, 1].to_i
    end

    def create_schema(schema_name)
      return unless schema_name

      db_conn.exec("CREATE SCHEMA #{db_conn.quote_ident(schema_name)}")
      logger.info "Создана схема #{schema_name}"
    rescue StandardError => e
      logger.error "Ошибка создания схемы #{schema_name}: #{e.message}"
      raise e
    end

    def drop_schema(schema_name)
      return unless schema_name

      db_conn.exec("DROP SCHEMA IF EXISTS #{db_conn.quote_ident(schema_name)} CASCADE")
    rescue StandardError => e
      logger.error "Ошибка при удалении схемы #{schema_name}: #{e.message}"
    end

    def create_tables(schema_name = nil)
      Gar.configuration.import_entities.each do |table_name|
        table_module = Gar::Entities.get_table_module(table_name)
        next unless table_module

        full_table_name = full_table_name(table_name, schema_name)
        schema_sql      = table_module::SCHEMA % full_table_name

        db_conn.exec(schema_sql)
        logger.info "Создана таблица #{full_table_name}"
      rescue StandardError => e
        logger.error "Ошибка создания таблицы #{full_table_name}: #{e.message}"
        raise e
      end
    end

    private

    # Схемы
    def schema_exists?(schema_name)
      db_conn.exec_params("SELECT * FROM information_schema.schemata WHERE schema_name = $1 LIMIT 1", [schema_name]).any?
    end

    def rename_schema(old_name, new_name)
      db_conn.exec("ALTER SCHEMA #{db_conn.quote_ident(old_name)} RENAME TO #{db_conn.quote_ident(new_name)}")
    end

    def get_database_version(schema_name)
      result =
        db.with_retry do |conn|
          conn.exec("SELECT version_id FROM #{db_conn.quote_ident(schema_name)}.database_version ORDER BY version_id DESC LIMIT 1")
        end
      result.ntuples.positive? ? result.getvalue(0, 0) : nil
    end

    def backup_current_schema(current_schema)
      return unless schema_exists?(current_schema)

      version        = get_database_version(current_schema)
      version_suffix = version ? "v#{version}" : Time.now.strftime("%Y%m%d_%H%M%S")
      backup_name    = "gar_backup_#{version_suffix}"

      drop_schema(backup_name) if schema_exists?(backup_name)
      rename_schema(current_schema, backup_name)

      logger.info "Текущая схема #{current_schema} переименована в #{backup_name}"
    rescue StandardError
      logger.info "Текущая схема #{current_schema} не существует, пропускаем backup"
    end

    # Индексы
    def create_indexes(schema_name = nil)
      all_indexes = collect_all_indexes(schema_name)
      return if all_indexes.empty?

      total = all_indexes.size
      logger.info "Создание #{total} индексов"
      create_indexes_sequential(all_indexes)
      logger.info "Создано #{total} индексов"
    end

    def create_indexes_parallel(all_indexes)
      execute_in_parallel(all_indexes) do |db, index_sql|
        db.with_retry do |conn|
          conn.exec(index_sql)
        end
      end
    end

    def create_indexes_sequential(all_indexes)
      total = all_indexes.size

      all_indexes.each_with_index do |index_sql, index|
        db.with_retry do |conn|
          conn.exec(index_sql)
        end
        log_progress(index + 1, total)
      end
    end

    def collect_all_indexes(schema_name)
      Gar.configuration.import_entities.flat_map do |table_name|
        table_module = Gar::Entities.get_table_module(table_name)
        next [] unless table_module

        full_table_name = full_table_name(table_name, schema_name)
        table_module::INDEXES.map { |tpl| tpl % full_table_name }
      end
    end

    # Импорт данных
    def import_tables(zip_path, schema_name)
      import_list  = build_import_list
      total_tables = import_list.length

      import_list.each_with_index do |table_info, index|
        import_table(zip_path, schema_name, table_info, index + 1, total_tables)
      end

      create_indexes(schema_name)
      logger.info "Индексы созданы"
    ensure
      cleanup_extracted_files(zip_path)
    end

    def import_table(zip_path, schema_name, table_info, processed, total)
      table_name = table_info[:table]
      table_key = table_info[:key]

      db.ensure_alive!

      logger.info "[#{processed}/#{total}] Импорт таблицы #{schema_name}.#{table_name}..."

      xml_files = extract_xml_for_table(zip_path, table_key)
      if xml_files.empty?
        logger.warn "Файлы для таблицы #{table_name} не найдены, пропускаем"
        return
      end

      import_xml_files_for_table(xml_files, table_name, schema_name)
      logger.info "Файлы таблицы #{table_name} обработаны"
    rescue StandardError => e
      logger.error "Ошибка импорта таблицы #{table_name}: #{e.message}"
      raise e
    end

    def import_xml_files_for_table(xml_files, table_name, schema_name)
      return if xml_files.empty?

      logger.info "  Обработка #{xml_files.length} XML файлов..."

      if parallel_import_enabled? && xml_files.size > 1
        import_files_parallel(xml_files, table_name, schema_name)
      else
        import_files_sequential(xml_files, table_name, schema_name)
      end

      logger.info "  Все #{xml_files.length} файлов обработаны"
    end

    def parallel_import_enabled?
      Gar.configuration.parallel_import
    end

    def import_files_parallel(xml_files, table_name, schema_name)
      execute_in_parallel(xml_files) do |db, xml_path|
        import_single_file(xml_path, table_name, schema_name, db)
      end
    end

    def import_files_sequential(xml_files, table_name, schema_name)
      total = xml_files.size

      xml_files.each_with_index do |xml_path, index|
        import_single_file(xml_path, table_name, schema_name, @db)
        log_progress(index + 1, total)
      end
    end

    def import_single_file(xml_path, table_name, schema_name, db)
      parser  = Gar::XmlParser.new
      options = build_parser_options(table_name)

      parser.parse_and_yield(xml_path:, table_name:, options:) do |batch, headers|
        copy_batch_data(db, batch, headers, table_name, schema_name)
      end
    end

    # Общая логика параллельного выполнения
    def execute_in_parallel(items)
      total = items.size
      return if total.zero?

      workers_count    = Gar.configuration.parallel_import_workers
      parallel_options = build_parallel_options(workers_count, total)

      Parallel.each(items, **parallel_options) do |item|
        worker_db = Gar::Database.new
        yield(worker_db, item)
        nil # Prevent returning PG::Result (cannot be marshalled between processes)
      ensure
        worker_db&.close
      end
    end

    def build_parallel_options(workers_count, total)
      progress       = 0
      progress_mutex = Mutex.new

      base_options =
        if Gar.configuration.parallel_import_strategy == :threads
          { in_threads: workers_count }
        else
          { in_processes: workers_count }
        end

      # finish callback вызывается в главном процессе после завершения КАЖДОГО item
      base_options[:finish] =
        lambda do |_item, _index, _result|
          progress_mutex.synchronize do
            progress += 1
            log_progress(progress, total)
          end
        end

      base_options
    end

    def split_into_chunks(array, num_chunks)
      chunk_size = (array.size.to_f / num_chunks).ceil
      array.each_slice(chunk_size).to_a
    end

    def copy_batch_data(db, batch, headers, table_name, schema_name = nil)
      return if batch.empty?

      db.with_retry do |conn|
        full_table_name = full_table_name(table_name, schema_name)
        quoted_headers  = headers.map { db_conn.quote_ident(_1.to_s) }.join(",")

        conn.copy_data("COPY #{full_table_name} (#{quoted_headers}) FROM STDIN") do
          batch.each do |record|
            values = headers.map { format_value_for_copy(record[_1]) }
            conn.put_copy_data("#{values.join("\t")}\n")
          end
        end
      end
    rescue StandardError => e
      logger.error "Ошибка групповой записи: #{e.message}"
      raise e
    end

    def format_value_for_copy(value)
      case value
      when nil then "\\N"
      when true then "t"
      when false then "f"
      when Integer, Float then value.to_s
      when DateTime, Time then value.strftime("%Y-%m-%d %H:%M:%S")
      when Date then value.strftime("%Y-%m-%d")
      else
        str = value.to_s
        str.match?(COPY_ESCAPE_REGEX) ? str.gsub(COPY_ESCAPE_REGEX, COPY_ESCAPE_CHARS) : str
      end
    end

    # Работа с файлами
    def extract_xml_for_table(zip_path, table_key)
      extract_dir = File.join(File.dirname(zip_path), File.basename(zip_path, ".*"))
      FileUtils.mkdir_p(extract_dir)

      xml_files = []

      Zip::File.open(zip_path) do |zip_file|
        zip_file.each do |entry|
          next unless entry.name.downcase.end_with?(".xml")
          next unless entry.name.include?(table_key)

          # Путь для извлечения
          extract_path = File.join(extract_dir, entry.name)
          FileUtils.mkdir_p(File.dirname(extract_path))

          entry.extract(extract_path) unless File.exist?(extract_path)
          xml_files << extract_path
        end
      end

      xml_files
    end

    def cleanup_extracted_files(zip_path)
      extract_dir = File.join(File.dirname(zip_path), File.basename(zip_path, ".zip"))
      return unless Dir.exist?(extract_dir)

      FileUtils.rm_rf(extract_dir)
      logger.debug "Директория #{extract_dir} удалена"
    end

    # Вспомогательные методы
    def save_version_info(schema_name, version_id)
      table_name = full_table_name("database_version", schema_name)

      db.with_retry do |conn|
        conn.exec <<-SQL
          CREATE TABLE IF NOT EXISTS #{table_name} (
            version_id INTEGER PRIMARY KEY,
            import_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
          )
        SQL

        conn.exec_params("INSERT INTO #{table_name} (version_id) VALUES ($1)", [version_id])
      end
    end

    def build_import_list
      Gar.configuration.import_entities.filter_map do |table_name|
        table_module = Gar::Entities.get_table_module(table_name)
        next unless table_module

        { table: table_name, key: table_module::XML_KEY }
      end
    end

    def build_parser_options(table_name)
      table_module = Gar::Entities.get_table_module(table_name)
      return {} unless table_module

      # Используем настройки из entity_options для данной таблицы
      table_options = Gar.configuration.entity_options&.[](table_name) || {}

      # Объединяем с дефолтными настройками из модуля если они есть
      default_options = table_module.const_defined?(:DEFAULT_PARSER_OPTIONS) ? table_module::DEFAULT_PARSER_OPTIONS : {}
      default_options.merge(table_options)
    end

    def full_table_name(name, schema_name)
      schema_name ? "#{schema_name}.#{name}" : name.to_s
    end

    def log_connection_info(message)
      pid = db_conn.respond_to?(:backend_pid) ? " (PID: #{db_conn.backend_pid})" : ""
      logger.debug "#{message}#{pid}"
    rescue StandardError
      logger.debug message
    end

    # Логировать каждые 10% или первый/последний файл
    def log_progress(processed, total)
      progress_percent = (processed.to_f / total * 100).to_i
      prev_percent     = ((processed - 1).to_f / total * 100).to_i
      return unless processed == 1 || progress_percent / 10 != prev_percent / 10 || processed == total

      logger.info "    Прогресс: #{processed}/#{total} файлов (#{progress_percent}%)"
    end
  end
end
