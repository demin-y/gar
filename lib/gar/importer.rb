# frozen_string_literal: true

require "parallel"

module Gar
  # Импорт архива ГАР в версионную схему gar_v<версия>.
  #
  # Схема создаётся заново (текущую импорт не трогает), таблицы — без ключей и индексов.
  # Файлы таблиц читаются потоком из zip одной очередью работ «таблица × субъект», крупные
  # первыми, и параллельно загружаются через COPY. Затем строятся первичные ключи и индексы
  # и собирается статистика. Состав данных — Configuration#import_tables, фильтры — keep_history
  # и param_types.
  class Importer
    include Loggable

    attr_reader :db_conn

    def initialize(db_conn = nil)
      @db_conn = db_conn || Database.create_connection
    end

    # Возвращает имя схемы с данными. region_codes — коды субъектов (папки архива), по умолчанию
    # все; on_progress — ->(done, total, stage): байты разобранного XML, stage = :import
    def import_full_base(zip_path, schema: nil, region_codes: nil, on_progress: nil)
      archive = Archive.new(zip_path)
      schema ||= "gar_v#{archive.version_id}"
      tables   = Gar.configuration.import_tables
      jobs     = archive.jobs(tables, region_codes:)

      logger.info "Импорт ГАР версии #{archive.version_id} в схему #{schema}: #{jobs.size} файлов, #{megabytes(jobs.sum(&:size))} XML"
      warn_missing_regions(jobs, region_codes)
      create_schema(schema, tables)
      save_version_info(schema, archive.version_id)
      load_data(archive, jobs, schema, on_progress)
      build_indexes(schema, tables)
      logger.info "Импорт завершён: схема #{schema}"
      schema
    rescue StandardError => e
      logger.error "Ошибка импорта#{" в схему #{schema}" if schema}: #{e.message}"
      raise if e.is_a?(Error)

      raise ImportError, "Ошибка импорта#{" в схему #{schema}" if schema}: #{e.message}"
    end

    def find_latest_full_base_zip(directory: nil)
      target_dir = directory || Gar.configuration.full_base_dir
      return nil unless Dir.exist?(target_dir)

      Dir.glob(File.join(target_dir, "*.zip")).max_by { |f| File.mtime(f) }
    end

    # Делает схему текущей (database_schema); прежняя текущая становится резервной
    # gar_backup_v<версия>. Переименования идут в одной транзакции: читатели видят либо
    # старую, либо новую схему.
    def switch_to_imported_schema(new_schema_name)
      raise ArgumentError, "Имя новой схемы не может быть пустым" if new_schema_name.to_s.empty?
      raise ArgumentError, "Схема #{new_schema_name} не существует" unless schema_exists?(new_schema_name)

      current_schema = Gar.configuration.database_schema
      return logger.info "Новая схема уже является текущей" if new_schema_name == current_schema

      db_conn.transaction do
        backup_current_schema(current_schema)
        rename_schema(new_schema_name, current_schema)
      end
      logger.info "Новая схема установлена как текущая: #{current_schema}"
    end

    private

    def create_schema(schema, tables)
      raise ImportError, "Схема #{schema} — текущая (database_schema): импорт в неё запрещён" if schema == Gar.configuration.database_schema

      logger.warn "Схема #{schema} осталась от прерванного импорта и будет создана заново" if schema_exists?(schema)
      db_conn.transaction do |conn|
        conn.exec("DROP SCHEMA IF EXISTS #{quote(schema)} CASCADE")
        conn.exec("CREATE SCHEMA #{quote(schema)}")
        tables.each { conn.exec(_1.create_sql(schema)) }
      end
    end

    def save_version_info(schema, version_id)
      table = "#{quote(schema)}.database_version"
      db_conn.exec("CREATE TABLE #{table} (version_id integer PRIMARY KEY, import_date timestamp DEFAULT CURRENT_TIMESTAMP)")
      db_conn.exec_params("INSERT INTO #{table} (version_id) VALUES ($1)", [version_id])
    end

    def load_data(archive, jobs, schema, on_progress)
      total = jobs.sum(&:size)
      done  = 0
      on_progress&.call(done, total, :import)

      each_loaded(archive, jobs, schema) do |job, count|
        done += job.size
        logger.info "  #{job}: #{count} записей, #{megabytes(job.size)} (#{total.zero? ? 100 : done * 100 / total}%)"
        on_progress&.call(done, total, :import)
      end
    end

    # Загружает файлы параллельно или по очереди; блок вызывается в этом процессе после
    # каждого загруженного файла с числом записей
    def each_loaded(archive, jobs, schema)
      return jobs.each { |job| yield job, load_job(db_conn, archive, job, schema) } unless Gar.configuration.parallel_import && jobs.size > 1

      parent_pid = Process.pid
      Parallel.each(jobs, **parallel_options, finish: ->(job, _index, count) { yield job, count }) do |job|
        discard_inherited_connections if Process.pid != parent_pid
        with_worker_connection { |conn| load_job(conn, archive, job, schema) }
      end
    end

    # Один файл — одна команда COPY в своей транзакции; возвращает число загруженных записей
    def load_job(conn, archive, job, schema)
      table  = Schema.fetch(job.table)
      reader = XmlReader.new(table, filters: filters_for(table), region_code: job.region_code)
      count  = 0

      conn.transaction do
        conn.exec("SET LOCAL synchronous_commit TO off")
        conn.copy_data(table.copy_sql(schema)) do
          count = archive.open(job) { |io| reader.read(io) { |chunk| conn.put_copy_data(chunk) } }
        end
      end
      count
    rescue StandardError => e
      raise ImportError, "Ошибка импорта файла #{job}: #{e.message}"
    end

    # Отбор записей при разборе: только актуальные (без keep_history) и нужные типы параметров
    def filters_for(table)
      config  = Gar.configuration
      filters = {}
      filters.merge!(table.actual.transform_values { [_1] }) if table.actual && !config.keep_history?(table.name)
      filters["TYPEID"] = config.param_types if table.params? && config.param_types != :all
      filters
    end

    # Ключи и индексы после загрузки: так COPY не тратит время на их поддержку
    def build_indexes(schema, tables)
      memory = db_conn.escape_literal(Gar.configuration.import_maintenance_work_mem)

      tables.each do |table|
        logger.info "  Ключи, индексы и статистика: #{table.name}"
        db_conn.transaction do |conn|
          conn.exec("SET LOCAL maintenance_work_mem TO #{memory}")
          [table.primary_key_sql(schema), *table.index_sqls(schema)].compact.each { conn.exec(_1) }
          conn.exec("ANALYZE #{table.qualified_name(schema)}")
        end
      end
    end

    def parallel_options
      workers = Gar.configuration.parallel_import_workers
      Gar.configuration.parallel_import_strategy == :threads ? { in_threads: workers } : { in_processes: workers }
    end

    # Воркер-процесс наследует соединения родителя. Их нельзя ни использовать, ни закрывать:
    # PQfinish (в том числе из финализатора при выходе) пошлёт серверу Terminate по общему
    # сокету и оборвёт соединение родителя. Поэтому сокеты унаследованных соединений
    # перенаправляются в /dev/null (как discard! в Active Record) — один раз на процесс.
    def discard_inherited_connections
      return if @discarded_in == Process.pid

      @discarded_in = Process.pid
      ObjectSpace.each_object(PG::Connection) do |conn|
        conn.socket_io.reopen(IO::NULL) unless conn.finished?
      rescue PG::Error, IOError, SystemCallError
        nil
      end
    end

    # У каждого воркера своё соединение: PG::Connection нельзя делить между потоками и процессами
    def with_worker_connection
      conn = Database.create_connection
      yield conn
    ensure
      conn&.close
    end

    def warn_missing_regions(jobs, region_codes)
      missing = Array(region_codes).map(&:to_s) - jobs.filter_map(&:region_code)
      logger.warn "В архиве нет папок субъектов: #{missing.join(', ')}" if missing.any?
    end

    def schema_exists?(schema_name)
      db_conn.exec_params("SELECT 1 FROM pg_namespace WHERE nspname = $1", [schema_name]).ntuples.positive?
    end

    def rename_schema(old_name, new_name)
      db_conn.exec("ALTER SCHEMA #{quote(old_name)} RENAME TO #{quote(new_name)}")
    end

    def backup_current_schema(current_schema)
      return unless schema_exists?(current_schema)

      version     = database_version(current_schema)
      backup_name = "gar_backup_#{version ? "v#{version}" : Time.now.strftime('%Y%m%d_%H%M%S')}"

      db_conn.exec("DROP SCHEMA IF EXISTS #{quote(backup_name)} CASCADE")
      rename_schema(current_schema, backup_name)
      logger.info "Текущая схема #{current_schema} переименована в #{backup_name}"
    end

    # Версия из database_version; nil, если схема создана не импортом гема
    def database_version(schema_name)
      table = "#{quote(schema_name)}.database_version"
      return unless db_conn.exec_params("SELECT to_regclass($1)", [table]).getvalue(0, 0)

      db_conn.exec("SELECT max(version_id) FROM #{table}").getvalue(0, 0)
    end

    def quote(identifier) = db_conn.quote_ident(identifier)

    def megabytes(bytes) = format("%.1f МБ", bytes / 1_048_576.0)
  end
end
