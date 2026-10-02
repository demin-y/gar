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
    # все; on_progress — ->(done, total, stage): байты разобранного XML, stage = :import.
    # Ошибки базы и файлов приходят как ImportError; незавершённая схема остаётся до повторного
    # импорта, который создаст её заново.
    def import_full_base(zip_path, schema: nil, region_codes: nil, on_progress: nil)
      archive = Archive.new(zip_path)
      schema ||= "gar_v#{archive.version_id}"
      tables   = Gar.configuration.import_tables
      jobs     = archive.jobs(tables, region_codes:)

      logger.info "Импорт ГАР версии #{archive.version_id} в схему #{schema}: #{jobs.size} файлов, #{Utils.format_size(jobs.sum(&:size))} XML"
      warn_missing_regions(jobs, region_codes)
      create_schema(schema, tables)
      load_data(archive, jobs, schema, on_progress)
      loaded = jobs.group_by(&:table).transform_values { |table_jobs| table_jobs.sum(&:size) }
      build_indexes(schema, tables.sort_by { -loaded.fetch(_1, 0) })
      save_version_info(schema, archive.version_id)
      logger.info "Импорт завершён: схема #{schema}"
      schema
    rescue PG::Error, SystemCallError, IOError => e
      raise ImportError, "Ошибка импорта в схему #{schema}: #{e.message}"
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

    # Версия записывается последней: схема без неё — незавершённый импорт
    def save_version_info(schema, version_id)
      db_conn.exec("CREATE TABLE #{version_table(schema)} (version_id integer PRIMARY KEY, import_date timestamp DEFAULT CURRENT_TIMESTAMP)")
      db_conn.exec_params("INSERT INTO #{version_table(schema)} (version_id) VALUES ($1)", [version_id])
    end

    def load_data(archive, jobs, schema, on_progress)
      total = jobs.sum(&:size)
      done  = 0
      on_progress&.call(done, total, :import)

      each_loaded(archive, jobs, schema) do |job, count|
        done += job.size
        logger.info "  #{job}: #{count} записей, #{Utils.format_size(job.size)} (#{total.zero? ? 100 : done * 100 / total}%)"
        on_progress&.call(done, total, :import)
      end
    end

    # Загружает файлы параллельно или по очереди; блок вызывается в этом процессе после
    # каждого загруженного файла с числом записей
    def each_loaded(archive, jobs, schema)
      if Gar.configuration.parallel_import && jobs.size > 1
        parent_pid = Process.pid
        Parallel.each(jobs, **parallel_options, finish: ->(job, _index, count) { yield job, count }) do |job|
          Database.discard_inherited_connections(parent_pid)
          with_worker_connection { |conn| load_job(conn, archive, job, schema) }
        end
      else
        jobs.each { |job| yield job, load_job(db_conn, archive, job, schema) }
      end
    rescue Parallel::DeadWorker
      raise ImportError, "Воркер импорта аварийно завершился — возможно, не хватило памяти. " \
                         "Уменьшите parallel_import_workers или отключите parallel_import"
    end

    # Один файл — одна команда COPY в своей транзакции; возвращает число загруженных записей.
    # Ошибка — ImportError с именем файла: её можно передать из воркер-процесса в родителя
    def load_job(conn, archive, job, schema)
      reader = XmlReader.new(job.table, filters: filters_for(job.table), region_code: job.region_code)
      count  = 0

      conn.transaction do
        conn.exec("SET LOCAL synchronous_commit TO off")
        conn.copy_data(job.table.copy_sql(schema)) do
          count = archive.stream(job) { |io| reader.read(io) { |chunk| conn.put_copy_data(chunk) } }
        end
      end
      count
    rescue StandardError => e
      raise ImportError, "Ошибка импорта файла #{job}: #{e.message}"
    end

    # Отбор записей при разборе: только актуальные (без keep_history) и нужные типы параметров
    def filters_for(table)
      config  = Gar.configuration
      filters = table.actual && !config.keep_history?(table.name) ? table.actual.dup : {}
      filters["TYPEID"] = Set.new(config.param_types.map(&:to_s)) if table.params? && config.param_types != :all
      filters
    end

    # Ключи и индексы после загрузки: так COPY не тратит время на их поддержку. Таблицы
    # независимы, при parallel_import они обрабатываются параллельно, крупные первыми; работа
    # идёт на сервере, поэтому хватает потоков. Память сервера — до maintenance_work_mem на
    # каждый воркер; задаётся, только если указан import_maintenance_work_mem.
    def build_indexes(schema, tables)
      if Gar.configuration.parallel_import && tables.size > 1
        Parallel.each(tables, in_threads: Gar.configuration.parallel_import_workers) do |table|
          with_worker_connection { |conn| build_table_indexes(conn, schema, table) }
        end
      else
        tables.each { |table| build_table_indexes(db_conn, schema, table) }
      end
    end

    def build_table_indexes(conn, schema, table)
      memory = Gar.configuration.import_maintenance_work_mem
      logger.info "  Ключи, индексы и статистика: #{table.name}"
      conn.transaction do
        conn.exec("SET LOCAL maintenance_work_mem TO #{conn.escape_literal(memory)}") if memory
        table.index_sqls(schema).each { conn.exec(_1) }
        conn.exec("ANALYZE #{table.qualified_name(schema)}")
      end
    end

    def parallel_options
      workers = Gar.configuration.parallel_import_workers
      Gar.configuration.parallel_import_strategy == :threads ? { in_threads: workers } : { in_processes: workers }
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

    # Версия из database_version; nil, если схема создана не импортом гема или импорт не завершён
    def database_version(schema_name)
      return unless db_conn.exec_params("SELECT to_regclass($1)", [version_table(schema_name)]).getvalue(0, 0)

      db_conn.exec("SELECT max(version_id) FROM #{version_table(schema_name)}").getvalue(0, 0)
    end

    def version_table(schema) = "#{quote(schema)}.database_version"

    def quote(identifier) = Schema.quote(identifier)
  end
end
