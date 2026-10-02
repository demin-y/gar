# frozen_string_literal: true

require "parallel"

module Gar
  # Импорт архива ГАР в версионную схему gar_v<версия>.
  #
  # Схема создаётся заново (текущую импорт не трогает), таблицы — без ключей и индексов.
  # Файлы таблиц читаются потоком из zip одной очередью работ «таблица × субъект», крупные
  # первыми, и параллельно загружаются через COPY. Затем из иерархий убираются строки
  # незагруженных объектов (prune_hierarchy), строятся первичные ключи и индексы и собирается
  # статистика. Состав данных — Configuration#import_tables и region_codes, фильтры —
  # keep_history и param_types. Настройки и стадия импорта записываются в gar_meta (Meta).
  class Importer
    include Loggable

    attr_reader :db_conn

    def initialize(db_conn = nil)
      @db_conn = db_conn ? Database.adopt(db_conn) : Database.create_connection
    end

    # Возвращает имя схемы с данными. source — путь к zip или Archive (в том числе
    # TestSupport::MemoryArchive). region_codes — коды субъектов (папки архива), по умолчанию
    # config.region_codes, пустой список — все; on_progress — ->(done, total, stage): байты
    # разобранного XML, stage = :import; parallel — параллельно ли загружать файлы и строить
    # индексы (по умолчанию config.parallel_import). Ошибки базы и файлов приходят как
    # ImportError; незавершённая схема (gar_meta.status = importing) остаётся до повторного
    # импорта, который создаст её заново.
    def import_full_base(source, schema: nil, region_codes: nil, on_progress: nil, parallel: Gar.configuration.parallel_import)
      archive      = open_archive(source)
      @parallel    = parallel
      schema     ||= "gar_v#{archive.version_id}"
      region_codes = region_codes.nil? ? Gar.configuration.region_codes : Configuration.region_codes(region_codes)
      tables       = Gar.configuration.import_tables
      jobs         = archive.jobs(tables, region_codes:)

      logger.info "Импорт ГАР версии #{archive.version_id} в схему #{schema}: #{jobs.size} файлов, #{Utils.format_size(jobs.sum(&:size))} XML"
      warn_missing_regions(jobs, region_codes)
      create_schema(schema, tables, archive:, region_codes:)
      load_data(archive, jobs, schema, on_progress)
      prune_hierarchies(schema, tables)
      loaded = jobs.group_by(&:table).transform_values { |table_jobs| table_jobs.sum(&:size) }
      build_indexes(schema, tables.sort_by { -loaded.fetch(_1, 0) })
      # Статус пишется последним: схема в статусе importing — незавершённый импорт
      Meta.update(db_conn, schema, "imported")
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

    def create_schema(schema, tables, archive:, region_codes:)
      raise ImportError, "Схема #{schema} — текущая (database_schema): импорт в неё запрещён" if schema == Gar.configuration.database_schema

      logger.warn "Схема #{schema} осталась от прерванного импорта и будет создана заново" if schema_exists?(schema)
      db_conn.transaction do |conn|
        conn.exec("DROP SCHEMA IF EXISTS #{quote(schema)} CASCADE")
        conn.exec("CREATE SCHEMA #{quote(schema)}")
        tables.each { conn.exec(_1.create_sql(schema)) }
        Meta.create(conn, schema, archive:, region_codes:, tables: tables.map(&:name))
      end
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
      if @parallel && jobs.size > 1
        Parallel.each(jobs, **parallel_options, finish: ->(job, _index, count) { yield job, count }) do |job|
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
      reader = XmlReader.new(job.table, filters: filters_for(job.table, archive.version_date), region_code: job.region_code)
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

    # Отбор записей при разборе: только актуальные (без keep_history) и нужные типы параметров.
    # Действующий параметр не закрыт изменением (CHANGEIDEND = 0) и не истёк к дате выгрузки
    # Фильтры проверяются по порядку: дешёвый отбор по типу — первым
    def filters_for(table, version_date)
      config  = Gar.configuration
      filters = {}
      filters["TYPEID"] = Set.new(config.param_types.map(&:to_s)) if table.params? && config.param_types != :all
      return filters if table.actual.nil? || config.keep_history?(table.name)

      filters.merge!(table.actual)
      cutoff = version_date.iso8601
      filters["ENDDATE"] = ->(end_date) { end_date.nil? || end_date > cutoff } if table.params?
      filters
    end

    # Ключи и индексы после загрузки: так COPY не тратит время на их поддержку. Крупные
    # таблицы первыми
    def build_indexes(schema, tables)
      each_on_server(tables) do |conn, table|
        logger.info "  Ключи, индексы и статистика: #{table.name}"
        conn.transaction do
          set_work_memory(conn, "maintenance_work_mem")
          table.index_sqls(schema).each { conn.exec(_1) }
          conn.exec("ANALYZE #{table.qualified_name(schema)}")
        end
      end
    end

    # Оставляет в иерархиях строки только загруженных объектов: строки участков, помещений и
    # машино-мест без их таблиц не нужны ни путям, ни поиску. Копия с отбором вместо DELETE:
    # таблица ещё без индексов, а копия не оставляет мёртвых строк. Отдельный шаг до индексов:
    # копия читает таблицы объектов, и её блокировки не должны задерживать их ключи
    def prune_hierarchies(schema, tables)
      objects     = tables.map(&:name) & Schema::OBJECT_TABLES
      hierarchies = tables.select { Configuration::HIERARCHY_TABLES.value?(_1.name) }
      return if !Gar.configuration.prune_hierarchy || objects.empty?

      loaded = objects.map { "SELECT object_id FROM #{Schema.fetch(_1).qualified_name(schema)}" }.join(" UNION ALL ")
      each_on_server(hierarchies) { |conn, table| prune_hierarchy(conn, schema, table, loaded) }
    end

    def prune_hierarchy(conn, schema, table, loaded)
      name   = table.qualified_name(schema)
      pruned = "#{quote(schema)}.#{quote("#{table.name}_pruned")}"
      conn.transaction do
        set_work_memory(conn, "work_mem") # хеш OBJECTID загруженных объектов
        kept = conn.exec("CREATE TABLE #{pruned} AS SELECT * FROM #{name} WHERE object_id IN (#{loaded})").cmd_tuples
        conn.exec("DROP TABLE #{name}")
        conn.exec("ALTER TABLE #{pruned} RENAME TO #{quote(table.name)}")
        logger.info "  Иерархия #{table.name}: #{kept} строк загруженных объектов"
      end
    end

    # Работа на сервере по таблицам (ключи, индексы, отбор иерархий): таблицы независимы, при
    # parallel_import обрабатываются параллельно в потоках — каждый со своим соединением
    def each_on_server(tables)
      if @parallel && tables.size > 1
        Parallel.each(tables, in_threads: Gar.configuration.parallel_import_workers) do |table|
          with_worker_connection { |conn| yield conn, table }
        end
      else
        tables.each { |table| yield db_conn, table }
      end
    end

    # Память сервера на операцию — import_maintenance_work_mem на каждый воркер; без настройки
    # действует значение сервера
    def set_work_memory(conn, setting)
      memory = Gar.configuration.import_maintenance_work_mem
      conn.exec("SET LOCAL #{setting} TO #{conn.escape_literal(memory)}") if memory
    end

    def parallel_options
      workers = Gar.configuration.parallel_import_workers
      Gar.configuration.parallel_import_strategy == :threads ? { in_threads: workers } : { in_processes: workers }
    end

    # У каждого воркера своё соединение: PG::Connection нельзя делить между потоками и процессами
    # Соединение потока или процесса — к той же базе, что и основное (переданное приложением
    # тоже), а не к config.database_url
    def with_worker_connection
      conn = Database.adopt(PG.connect(@db_conn.conninfo_hash.compact))
      yield conn
    ensure
      conn&.close
    end

    def open_archive(source) = source.is_a?(Archive) ? source : Archive.new(source)

    def warn_missing_regions(jobs, region_codes)
      missing = region_codes - jobs.filter_map(&:region_code)
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

      version     = Meta.read(db_conn, current_schema)&.version_id
      backup_name = "gar_backup_#{version ? "v#{version}" : Time.now.strftime('%Y%m%d_%H%M%S')}"

      db_conn.exec("DROP SCHEMA IF EXISTS #{quote(backup_name)} CASCADE")
      rename_schema(current_schema, backup_name)
      logger.info "Текущая схема #{current_schema} переименована в #{backup_name}"
    end

    def quote(identifier) = Schema.quote(identifier)
  end
end
