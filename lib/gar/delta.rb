# frozen_string_literal: true

module Gar
  # Дельта ГАР — изменения выгрузки относительно предыдущей версии: архив той же структуры, что
  # и полный (version.txt, справочники в корне, папки субъектов), только с изменёнными записями.
  #
  # Дельта применяется к схеме (по умолчанию текущей) в одной транзакции: читатели видят базу
  # до дельты или после. Файлы таблиц схемы (gar_meta.tables) её субъектов (region_codes)
  # читаются во временные таблицы и сливаются по первичному ключу: запись, прошедшая фильтры
  # схемы (актуальность без keep_history, типы и действие параметров, prune_hierarchy), — upsert,
  # не прошедшая — удаляется. У затронутых объектов и их потомков пересобираются пути, у их
  # предков — ранги (PathBuilder#rebuild). Версия в gar_meta и журнал gar_updates обновляются в
  # той же транзакции, поэтому прерванная дельта откатывается целиком, а повторная пропускается.
  #
  #   Gar::Delta.new.apply("downloads/delta/gar_delta_xml_v20260120.zip")
  class Delta
    include Loggable

    UPDATES = "gar_updates"
    # Колонки, от которых зависят пути: запись, у которой изменилось только остальное (даты,
    # CHANGEID), путей не меняет
    PATH_COLUMNS = {
      address_objects: [:name, :type_name, :is_actual, :is_active],
      houses:          [:house_num, :add_num1, :add_num2, :house_type, :add_type1, :add_type2, :is_actual, :is_active],
      adm_hierarchy:   [:path, :is_active],
      mun_hierarchy:   [:path, :is_active]
    }.freeze

    attr_reader :db_conn, :schema

    def initialize(db_conn = nil, schema: Gar.configuration.database_schema)
      @db_conn = db_conn ? Database.adopt(db_conn) : Database.create_connection
      @schema  = schema
    end

    # Применяет дельту source (путь к zip или Archive) и возвращает её версию; дельта не новее
    # схемы пропускается (nil). Дельты применяются строго по порядку версий: пропущенную
    # промежуточную дельту этот метод не заметит (цепочку проверяет Gar.update!).
    # on_progress — ->(done, total, stage): байты XML дельты, stage = :delta. Схема без gar_meta
    # или с незавершённым импортом, ошибки базы и файлов — ImportError; база занята — LockedError
    def apply(source, on_progress: nil)
      archive = Archive.open(source)
      Database.with_lock(db_conn, "Применение дельты #{archive.version_id} к схеме #{schema}") do
        meta = Meta.read(db_conn, schema) or raise ImportError, "В схеме #{schema} нет gar_meta: дельту не к чему применять"
        raise ImportError, "Импорт в схему #{schema} не завершён: дельта применяется после него" if meta.status == "importing"

        if archive.version_id <= meta.version_id
          logger.info "Дельта #{archive.version_id} не новее схемы #{schema} (#{meta.version_id}): пропущена"
          next
        end

        db_conn.transaction { apply_changes(archive, meta, on_progress) }
        archive.version_id
      end
    rescue PG::Error, SystemCallError, IOError => e
      raise ImportError, "Ошибка применения дельты к схеме #{schema}: #{e.message}"
    end

    private

    def apply_changes(archive, meta, on_progress)
      db_conn.exec("SET LOCAL client_min_messages TO warning") # без NOTICE от IF [NOT] EXISTS
      jobs   = archive.jobs(meta.tables.map { Schema.fetch(_1) }, region_codes: meta.region_codes)
      # Иерархии — после объектов: prune_hierarchy проверяет, загружен ли объект
      tables = jobs.map(&:table).uniq.sort_by { [hierarchy?(_1) ? 1 : 0, _1.name] }
      logger.info "Дельта #{archive.version_id} → схема #{schema}: #{jobs.size} файлов, #{Utils.format_size(jobs.sum(&:size))} XML"
      stage(archive, tables, jobs, on_progress)

      counts = nil
      if meta.status == "ready"
        PathBuilder.new(db_conn, schema:).rebuild(path_object_ids(tables), param_object_ids: param_object_ids(tables)) do
          counts = merge_all(tables, meta, archive)
        end
      else
        counts = merge_all(tables, meta, archive)
      end
      Meta.advance(db_conn, schema, archive)
      journal(archive, counts)
      logger.info "Дельта #{archive.version_id} применена: #{counts[:upserted]} записей добавлено или изменено, #{counts[:deleted]} удалено"
    end

    # Все записи файлов дельты — во временные таблицы (без фильтров: не прошедшие их удаляются)
    def stage(archive, tables, jobs, on_progress)
      tables.each { db_conn.exec("CREATE TEMP TABLE #{staging(_1)} (#{_1.copy_columns.map(&:definition).join(', ')}) ON COMMIT DROP") }
      total = jobs.sum(&:size)
      done  = 0
      on_progress&.call(done, total, :delta)
      jobs.each do |job|
        reader = XmlReader.new(job.table, region_code: job.region_code)
        db_conn.copy_data(job.table.copy_sql("pg_temp")) do
          archive.stream(job) { |io| reader.read(io) { db_conn.put_copy_data(_1) } }
        end
        on_progress&.call(done += job.size, total, :delta)
      rescue StandardError => e
        raise ImportError, "Ошибка в файле дельты #{job}: #{e.message}"
      end
    end

    # Записи всех таблиц дельты; возвращает { upserted:, deleted: }
    def merge_all(tables, meta, archive)
      tables.each_with_object({ upserted: 0, deleted: 0 }) do |table, counts|
        merge(table, meta, archive).each { |key, count| counts[key] += count }
      end
    end

    # Сливает записи таблицы: не прошедшие фильтры удаляются, остальные — upsert по ключу.
    # Журнал без ключа (change_history) только пополняется
    def merge(table, meta, archive)
      target = table.qualified_name(schema)
      if table.primary_key.empty?
        return { upserted: db_conn.exec("INSERT INTO #{target} (#{columns(table)}) SELECT #{columns(table)} FROM #{staging(table)}").cmd_tuples }
      end

      key     = table.primary_key.map { quote(_1) }
      keep    = keep_condition(table, meta, archive)
      updates = (table.copy_columns.map(&:name) - table.primary_key).map { "#{quote(_1)} = EXCLUDED.#{quote(_1)}" }
      track_moves(table, keep) if hierarchy?(table)
      deleted = db_conn.exec("DELETE FROM #{target} t USING #{staging(table)} s " \
                             "WHERE #{key.map { "t.#{_1} = s.#{_1}" }.join(' AND ')} AND (#{keep}) IS NOT TRUE").cmd_tuples
      upserted = db_conn.exec(<<~SQL).cmd_tuples
        INSERT INTO #{target} (#{columns(table)})
        SELECT DISTINCT ON (#{key.join(', ')}) #{columns(table)} FROM #{staging(table)} s WHERE #{keep} ORDER BY #{key.join(', ')}
        ON CONFLICT (#{key.join(', ')}) DO #{updates.empty? ? 'NOTHING' : "UPDATE SET #{updates.join(', ')}"}
      SQL
      upserted += move_descendants(table) if hierarchy?(table)
      logger.debug "  #{table.name}: #{upserted} добавлено или изменено, #{deleted} удалено"
      { upserted:, deleted: }
    end

    # Перенос в иерархии: ФНС присылает новую строку самого объекта (новый PARENTOBJID и PATH),
    # а строки его потомков — не обязательно, и их PATH остаётся со старой цепочкой. До слияния
    # запоминаем старый и новый PATH перенесённых объектов (moves)...
    def track_moves(table, keep)
      db_conn.exec(<<~SQL)
        CREATE TEMP TABLE #{moves(table)} ON COMMIT DROP AS
        SELECT DISTINCT ON (s.object_id) s.object_id, t.path AS old_path, s.path AS new_path
        FROM #{staging(table)} s JOIN #{table.qualified_name(schema)} t ON t.object_id = s.object_id AND t.is_active
        WHERE #{keep} AND t.path <> s.path
        ORDER BY s.object_id, s.id DESC
      SQL
    end

    # ...после — меняем начало PATH у строк потомков, где оно ещё старое (присланные дельтой
    # строки потомков уже с новым PATH и не меняются). Потомки — по parent_obj_id (индекс)
    def move_descendants(table)
      target = table.qualified_name(schema)
      db_conn.exec(<<~SQL).cmd_tuples
        WITH RECURSIVE d AS (
          SELECT m.object_id AS root, h.id, h.object_id FROM #{moves(table)} m JOIN #{target} h ON h.parent_obj_id = m.object_id
          UNION
          SELECT d.root, h.id, h.object_id FROM d JOIN #{target} h ON h.parent_obj_id = d.object_id
        )
        UPDATE #{target} h SET path = m.new_path || substr(h.path, length(m.old_path) + 1)
        FROM d JOIN #{moves(table)} m ON m.object_id = d.root
        WHERE h.id = d.id AND starts_with(h.path, m.old_path || '.')
      SQL
    end

    def moves(table) = "pg_temp.gar_moves_#{table.name}"

    # Фильтры записи s — как при импорте схемы (Importer#filters_for), но по настройкам из
    # gar_meta; плюс prune_hierarchy: строка иерархии — только у загруженного объекта
    def keep_condition(table, meta, archive)
      conditions = [*record_conditions(table, meta, archive), *prune_condition(table, meta)]
      conditions.empty? ? "true" : conditions.join(" AND ")
    end

    def record_conditions(table, meta, archive)
      conditions = []
      conditions << "s.type_id = ANY(#{literal(Database.array(meta.param_types))}::integer[])" if table.params? && meta.param_types
      return conditions if table.actual.nil? || meta.keep_history.include?(table.name)

      table.actual.each { |attribute, value| conditions << "s.#{quote(column(table, attribute))} = #{literal(value)}" }
      conditions << "(s.end_date IS NULL OR s.end_date > #{literal(archive.version_date.iso8601)})" if table.params?
      conditions
    end

    def prune_condition(table, meta)
      loaded = meta.tables & Schema::OBJECT_TABLES
      return unless meta.prune_hierarchy && hierarchy?(table) && loaded.any?

      "(#{loaded.map { "EXISTS (SELECT 1 FROM #{Schema.fetch(_1).qualified_name(schema)} o WHERE o.object_id = s.object_id)" }.join(' OR ')})"
    end

    # OBJECTID записей дельты (до слияния), у которых изменились колонки путей (PATH_COLUMNS)
    # или которых ещё нет в схеме
    def path_object_ids(tables)
      selects =
        tables.filter_map do |table|
          columns = PATH_COLUMNS[table.name] or next
          changed = "(#{columns.map { "t.#{quote(_1)}" }.join(', ')}) IS DISTINCT FROM (#{columns.map { "s.#{quote(_1)}" }.join(', ')})"
          "SELECT s.object_id FROM #{staging(table)} s LEFT JOIN #{table.qualified_name(schema)} t ON t.id = s.id WHERE t.id IS NULL OR #{changed}"
        end
      selects.empty? ? [] : db_conn.exec(selects.join(" UNION ")).column_values(0).map(&:to_i)
    end

    # OBJECTID адресных объектов с изменёнными параметрами (признак административного центра)
    def param_object_ids(tables)
      table = tables.find { _1.name == :addr_obj_params }
      table ? db_conn.exec("SELECT DISTINCT object_id FROM #{staging(table)}").column_values(0).map(&:to_i) : []
    end

    def journal(archive, counts)
      updates = "#{quote(schema)}.#{quote(UPDATES)}"
      db_conn.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{updates} (
          version_id integer PRIMARY KEY, version_date date NOT NULL, applied_at timestamptz NOT NULL DEFAULT now(),
          upserted bigint NOT NULL, deleted bigint NOT NULL, gem_version text NOT NULL
        )
      SQL
      db_conn.exec_params("INSERT INTO #{updates} (version_id, version_date, upserted, deleted, gem_version) VALUES ($1, $2, $3, $4, $5)",
                          [archive.version_id, archive.version_date.iso8601, counts[:upserted], counts[:deleted], VERSION])
    end

    def hierarchy?(table) = Configuration::HIERARCHY_TABLES.value?(table.name)

    # Временная таблица записей дельты: одноимённая в pg_temp (вся SQL гема — с именем схемы)
    def staging(table) = table.qualified_name("pg_temp")

    def columns(table) = table.copy_columns.map { quote(_1.name) }.join(", ")

    def column(table, attribute) = table.columns.find { _1.attribute == attribute }.name

    def literal(value) = db_conn.escape_literal(value.to_s)

    def quote(identifier) = Schema.quote(identifier)
  end
end
