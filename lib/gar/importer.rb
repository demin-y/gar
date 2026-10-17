# frozen_string_literal: true

require "parallel"

module Gar
  # Импорт архива ГАР в версионную схему <config.database_schema>_v<версия> («gar_v20260116»).
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

    # Возвращает имя схемы с данными (по умолчанию <config.database_schema>_v<версия>). source —
    # путь к zip или Archive (в том числе TestSupport::MemoryArchive). region_codes — коды
    # субъектов (папки архива), по умолчанию config.region_codes, пустой список — все;
    # on_progress — ->(done, total, stage): байты разобранного XML (stage = :import), затем
    # таблицы с готовыми ключами и индексами (:indexes); parallel — параллельно ли загружать
    # файлы и строить индексы (по умолчанию config.parallel_import).
    #
    # Повторный вызов безопасен: схема, уже загруженная из той же версии с теми же
    # настройками (gar_meta.status imported или ready), не загружается заново; незавершённая
    # (importing) или загруженная иначе создаётся заново. С reuse_current: если так загружена
    # и готова (ready) текущая схема, возвращается она (Gar.import). Во время импорта база
    # заблокирована для других изменяющих операций (LockedError). Ошибки базы и файлов —
    # ImportError.
    def import_full_base(source, schema: nil, region_codes: nil, on_progress: nil, parallel: Gar.configuration.parallel_import, reuse_current: false)
      archive      = Archive.open(source)
      @parallel    = parallel
      current      = Gar.configuration.database_schema
      schema     ||= Schemas.import_name(current, archive.version_id)
      region_codes = region_codes.nil? ? Gar.configuration.region_codes : Configuration.region_codes(region_codes)
      tables       = Gar.configuration.import_tables

      Database.with_lock(db_conn, "Импорт в схему #{schema}") do
        next current if reuse_current && imported?(current, archive, region_codes, tables, statuses: [Meta::READY])
        next schema if imported?(schema, archive, region_codes, tables, statuses: [Meta::IMPORTED, Meta::READY])

        import(archive, schema, region_codes, tables, on_progress)
      end
    rescue PG::Error, SystemCallError, IOError => e
      raise ImportError, "Ошибка импорта в схему #{schema}: #{e.message}"
    end

    # Последний скачанный архив в directory (по умолчанию config.full_base_dir) или nil. С
    # region_codes — только архив, в котором есть эти субъекты и таблицы config.import_tables:
    # полный или частичный с ними (Gar.download с субъектами); пустой список — только полный
    def self.find_latest_full_base_zip(directory: nil, region_codes: nil)
      zips = Dir.glob(File.join(directory || Gar.configuration.full_base_dir, "*.zip")).sort_by { -File.mtime(_1).to_f }
      return zips.first if region_codes.nil?

      codes = Configuration.region_codes(region_codes)
      zips.find do |zip|
        Archive.new(zip).covers?(codes, Gar.configuration.import_tables)
      rescue ImportError # не zip или повреждён
        false
      end
    end

    # Делает схему текущей (database_schema); прежняя текущая становится резервной
    # <текущая>_backup_v<версия>, резервные сверх config.keep_backups удаляются (Schemas.switch).
    # Переименования идут в одной транзакции: читатели видят либо старую, либо новую схему
    def switch_to_imported_schema(new_schema_name)
      raise ArgumentError, "Имя новой схемы не может быть пустым" if new_schema_name.to_s.empty?

      current = Gar.configuration.database_schema
      Database.with_lock(db_conn, "Переключение на схему #{new_schema_name}") do
        raise ArgumentError, "Схема #{new_schema_name} не существует" unless Schemas.exists?(db_conn, new_schema_name)
        next logger.info("Схема #{new_schema_name} уже текущая") if new_schema_name == current

        Schemas.switch(db_conn, new_schema_name, current:, keep_backups: Gar.configuration.keep_backups)
      end
    end

    private

    def import(archive, schema, region_codes, tables, on_progress)
      jobs = archive.jobs(tables, region_codes:)
      logger.info "Импорт ГАР версии #{archive.version_id} в схему #{schema}: #{jobs.size} файлов, #{Utils.format_size(jobs.sum(&:size))} XML"
      warn_missing_regions(jobs, region_codes)
      create_schema(schema, tables, archive:, region_codes:)
      load_data(archive, jobs, schema, on_progress)
      prune_hierarchies(schema, tables)
      loaded = jobs.group_by(&:table).transform_values { |table_jobs| table_jobs.sum(&:size) }
      build_indexes(schema, tables.sort_by { -loaded.fetch(_1, 0) }, on_progress)
      # Статус пишется последним: схема в статусе importing — незавершённый импорт
      Meta.update(db_conn, schema, Meta::IMPORTED)
      logger.info "Импорт завершён: схема #{schema}"
      schema
    end

    # Схема в статусе из statuses загружена из той же версии с теми же настройками
    def imported?(schema, archive, region_codes, tables, statuses:)
      meta = Meta.read(db_conn, schema)
      return false unless statuses.include?(meta&.status) && meta.same_import?(archive.version_id, region_codes:, tables: tables.map(&:name))

      logger.info "Схема #{schema} уже загружена из версии #{archive.version_id} с теми же настройками (#{meta.status}): импорт не нужен"
      true
    end

    def create_schema(schema, tables, archive:, region_codes:)
      raise ImportError, "Схема #{schema} — текущая (database_schema): импорт в неё запрещён" if schema == Gar.configuration.database_schema

      logger.warn "Схема #{schema} осталась от прерванного импорта или загружена иначе и будет создана заново" if Schemas.exists?(db_conn, schema)
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
      conn.transaction do
        conn.exec("SET LOCAL synchronous_commit TO off")
        archive.copy(conn, job, schema, filters: filters_for(job.table, archive.version_date))
      end
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
    # таблицы первыми; прогресс — число готовых таблиц
    def build_indexes(schema, tables, on_progress)
      done = 0
      on_progress&.call(done, tables.size, :indexes)
      each_on_server(tables, finish: ->(*) { on_progress&.call(done += 1, tables.size, :indexes) }) do |conn, table|
        logger.info "  Ключи, индексы и статистика: #{table.name}"
        conn.transaction do
          Database.set_work_memory(conn, "maintenance_work_mem")
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
      pruned = Schema.qualify(schema, "#{table.name}_pruned")
      conn.transaction do
        Database.set_work_memory(conn, "work_mem") # хеш OBJECTID загруженных объектов
        kept = conn.exec("CREATE TABLE #{pruned} AS SELECT * FROM #{name} WHERE object_id IN (#{loaded})").cmd_tuples
        conn.exec("DROP TABLE #{name}")
        conn.exec("ALTER TABLE #{pruned} RENAME TO #{quote(table.name)}")
        logger.info "  Иерархия #{table.name}: #{kept} строк загруженных объектов"
      end
    end

    # Работа на сервере по таблицам (ключи, индексы, отбор иерархий): таблицы независимы, при
    # parallel_import обрабатываются параллельно в потоках — каждый со своим соединением.
    # finish вызывается после каждой таблицы по одному (Parallel — под своим мьютексом)
    def each_on_server(tables, finish: nil)
      if @parallel && tables.size > 1
        Parallel.each(tables, in_threads: Gar.configuration.parallel_import_workers, finish:) do |table|
          with_worker_connection { |conn| yield conn, table }
        end
      else
        tables.each do |table|
          yield db_conn, table
          finish&.call
        end
      end
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

    def warn_missing_regions(jobs, region_codes)
      missing = region_codes - jobs.filter_map(&:region_code)
      logger.warn "В архиве нет папок субъектов: #{missing.join(', ')}" if missing.any?
    end

    def quote(identifier) = Schema.quote(identifier)
  end
end
