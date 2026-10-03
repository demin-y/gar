# frozen_string_literal: true

module Gar
  # Полные пути адресных объектов и домов по иерархиям: «Кировская обл, Киров г, Ленина ул, д. 12 к. 2»
  # в full_adm_path/full_mun_path, их tsvector для полнотекстового поиска и OBJECTID объектов
  # пути в adm_path_ids/mun_path_ids (поиск в границах, пересборка поддерева).
  #
  # Какие пути строить, решает состав схемы: строятся пути таблиц с путями (Schema, колонки
  # full_*_path) по загруженным иерархиям. Заполняются только пустые пути, по возрастанию id,
  # батчами — по одному запросу на батч, обе иерархии сразу. Поэтому прерванное построение
  # можно продолжить, а после invalidate — пересобрать только очищенное поддерево.
  #
  #   Gar::PathBuilder.new(conn, schema: "gar_v20260116").build
  class PathBuilder
    include Loggable

    # Таблица после пакетных UPDATE растёт вдвое: VACUUM возвращает место под следующие батчи
    VACUUM_EVERY_N_BATCHES = 50
    BATCH_SIZE             = 25_000
    # Параметр «Административный центр субъекта РФ» (AS_PARAM_TYPES)
    CAPITAL_PARAM          = 22
    # Временные таблицы rebuild: объекты, у которых пересчитывается признак центра, и изменение
    # числа домов адресных объектов
    RANKED       = "pg_temp.gar_rebuild_objects"
    HOUSE_COUNTS = "pg_temp.gar_house_counts"

    # Номер дома с типами: тип пишется, только если есть его номер
    HOUSE_NUMBER = <<~SQL
      NULLIF(concat_ws(' ',
        CASE WHEN t.house_num IS NOT NULL THEN ht.short_name END, t.house_num,
        CASE WHEN t.add_num1 IS NOT NULL THEN a1.short_name END, t.add_num1,
        CASE WHEN t.add_num2 IS NOT NULL THEN a2.short_name END, t.add_num2), '')
    SQL
    private_constant :HOUSE_NUMBER

    attr_reader :db_conn, :schema

    def initialize(db_conn = nil, schema: Gar.configuration.database_schema)
      @db_conn = db_conn ? Database.adopt(db_conn) : Database.create_connection
      @schema  = schema
    end

    # Заполняет пустые пути и строит их индексы, затем отмечает в gar_meta, что схема готова.
    # on_progress — ->(done, total, stage): просмотренные записи с пустым путём, stage = :paths.
    # Возвращает число записей, у которых заполнился хотя бы один путь; записи без строки в
    # иерархии остаются пустыми. Без адресных объектов или иерархий — ConfigurationError; база
    # занята другой изменяющей операцией — LockedError.
    def build(batch_size: BATCH_SIZE, on_progress: nil)
      Database.with_lock(db_conn, "Построение путей схемы #{schema}") { build_paths(batch_size, on_progress) }
    end

    # Очищает пути объектов object_ids (OBJECTID) и всех их потомков по загруженным иерархиям
    # (PARENTOBJID), чтобы build пересобрал их: после переименования, переноса в иерархии или
    # удаления объекта. Возвращает число очищенных записей
    def invalidate(object_ids)
      return 0 if hierarchies.empty?

      Database.with_lock(db_conn, "Очистка путей схемы #{schema}") do
        Database.transaction(db_conn) do
          objects = descendants(object_ids, "cleared")
          tables.sum { db_conn.exec("UPDATE #{qualified(_1)} SET #{reset_paths} WHERE id IN (SELECT id FROM #{rows(_1, objects)})").cmd_tuples }
        end
      end
    end

    # Пересборка после изменения данных (дельта): блок меняет записи объектов object_ids, затем
    # пути этих объектов и их потомков строятся заново. Число домов адресных объектов меняется
    # на разницу «после − до» по домам этого поддерева (а не пересчитывается по всем домам их
    # предков — субъекта целиком); признак центра пересчитывается у объектов путей поддерева и
    # у param_object_ids (изменились параметры). Всё — в одной транзакции (в открытой — в ней
    # же) и без VACUUM: читатели видят пути до изменения или после. Возвращает число записей с
    # новыми путями
    def rebuild(object_ids, param_object_ids: [])
      Database.with_lock(db_conn, "Пересборка путей схемы #{schema}") do
        Database.transaction(db_conn) do
          if hierarchies.empty? || !table_exists?(:address_objects)
            yield
            next 0
          end

          houses = tables.include?(:houses)
          scope_table(RANKED, param_object_ids)
          # До изменения: записи могут уйти из поддерева или исчезнуть
          before = descendants(object_ids, "before").then { |objects| tables.to_h { [_1, rows(_1, objects)] } }
          before.each { |table, changed| add_ancestors(table, changed) }
          count_houses(before[:houses], ids: ids_param(object_ids)) if houses
          yield
          rebuild_paths(descendants(object_ids, "after")).tap do
            db_conn.exec("ANALYZE #{RANKED}")
            update_ranks(scope: RANKED) if houses
          end
        end
      end
    end

    # Таблицы с путями
    def tables = @tables ||= Schema::REGIONAL.select(&:paths?).map(&:name).select { table_exists?(_1) }

    # Загруженные иерархии
    def hierarchies = @hierarchies ||= Configuration::HIERARCHY_TABLES.select { table_exists?(_2) }.keys

    private

    def build_paths(batch_size, on_progress)
      raise ConfigurationError, "В схеме #{schema} нет адресных объектов: пути строить не из чего" unless table_exists?(:address_objects)
      raise ImportError, "Импорт в схему #{schema} не завершён: пути строятся после него" if Meta.read(db_conn, schema)&.importing?
      raise ConfigurationError, "В схеме #{schema} нет ни одной иерархии (adm_hierarchy, mun_hierarchy)" if hierarchies.empty?

      pending     = tables.to_h { [_1, db_conn.exec("SELECT count(*) FROM #{qualified(_1)} WHERE #{empty_condition}").getvalue(0, 0).to_i] }
      total       = pending.values.sum
      done        = 0
      updated     = 0
      on_progress&.call(done, total, :paths)
      [*tables, *hierarchies.map { Configuration::HIERARCHY_TABLES[_1] }].uniq.each { db_conn.exec("ANALYZE #{qualified(_1)}") }

      tables.each do |table|
        logger.info "Заполнение путей #{table} (#{hierarchies.join(', ')}): #{pending[table]} записей, батч #{batch_size}"
        updated += fill(table, batch_size) { on_progress&.call(done + _1, total, :paths) }
        done    += pending[table]
        create_path_indexes(table)
      end
      update_ranks if tables.include?(:houses)
      Meta.update(db_conn, schema, Meta::READY)
      updated
    end

    # Батчи по id с временным частичным индексом по пустым путям; блок получает число
    # просмотренных записей. Курсор id пропускает записи, путь которых не собрался
    def fill(table, batch_size)
      updated = 0
      with_empty_paths_index(table) do
        updated =
          each_batch(batch_sql(table), batch_size) do |seen, batch|
            yield seen
            vacuum(table) if (batch % VACUUM_EVERY_N_BATCHES).zero?
          end
      end
      logger.info "Заполнение путей #{table} завершено: #{updated} записей"
      updated
    end

    # Выполняет батчи sql по курсору id до конца; блок — после каждого: число просмотренных
    # записей и номер батча. Возвращает число записей с новыми путями
    def each_batch(sql, batch_size)
      last_id = 0
      seen    = 0
      updated = 0
      (1..).each do |batch|
        row = db_conn.exec_params(sql, [last_id, batch_size])[0]
        break unless row["last_id"]

        last_id  = row["last_id"].to_i
        seen    += row["seen"].to_i
        updated += row["updated"].to_i
        yield seen, batch if block_given?
      end
      updated
    end

    # Очищает пути поддерева ids и заполняет их заново батчами по списку очищенных записей (без
    # индекса пустых путей и VACUUM); предки пересобранных записей — в RANKED, их дома — в
    # изменение числа домов
    def rebuild_paths(objects)
      tables.sum do |table|
        changed = rows(table, objects)
        db_conn.exec("UPDATE #{qualified(table)} SET #{reset_paths} WHERE id IN (SELECT id FROM #{changed})")
        each_batch(batch_sql(table, changed), BATCH_SIZE).tap do
          add_ancestors(table, changed)
          count_houses(changed, sign: 1) if table == :houses
        end
      end
    end

    # Объекты object_ids и их потомки по загруженным иерархиям — во временную таблицу
    # pg_temp.gar_<label>_objects. Обход по уровням: маленькая таблица уровня соединяется с
    # иерархиями по индексу parent_obj_id, поэтому время зависит от размера поддерева. Условие
    # «*_path_ids && массив OBJECTID» планировщик для тысяч OBJECTID считает неселективным и
    # сравнивает массивы в каждой строке таблицы — десятки секунд на дельту двух субъектов
    def descendants(object_ids, label)
      objects  = scope_table("pg_temp.gar_#{label}_objects", object_ids)
      level    = scope_table("pg_temp.gar_level", object_ids)
      found    = scope_table("pg_temp.gar_level_next")
      children = hierarchies.map { "SELECT h.object_id FROM #{level} l JOIN #{qualified(Configuration::HIERARCHY_TABLES[_1])} h ON h.parent_obj_id = l.id AND h.is_active" }
      loop do
        db_conn.exec("ANALYZE #{level}")
        added = db_conn.exec("INSERT INTO #{found} SELECT object_id FROM (#{children.join(' UNION ')}) c " \
                             "WHERE NOT EXISTS (SELECT 1 FROM #{objects} o WHERE o.id = c.object_id)").cmd_tuples
        break if added.zero?

        db_conn.exec("INSERT INTO #{objects} SELECT id FROM #{found}")
        db_conn.exec("TRUNCATE #{level}")
        db_conn.exec("INSERT INTO #{level} SELECT id FROM #{found}")
        db_conn.exec("TRUNCATE #{found}")
      end
      db_conn.exec("ANALYZE #{objects}")
      objects
    end

    # Записи таблицы table объектов из временной таблицы objects — во временную таблицу id
    def rows(table, objects)
      rows = scope_table("#{objects.delete_suffix('_objects')}_#{table}")
      db_conn.exec("INSERT INTO #{rows} SELECT t.id FROM #{qualified(table)} t JOIN #{objects} o ON t.object_id = o.id")
      db_conn.exec("ANALYZE #{rows}")
      rows
    end

    # Объекты путей (предки и сами записи) записей таблицы table из временной таблицы rows — в RANKED
    def add_ancestors(table, rows)
      ids = hierarchies.map { "SELECT unnest(#{_1}_path_ids) FROM #{qualified(table)} WHERE id IN (SELECT id FROM #{rows})" }
      db_conn.exec("INSERT INTO #{RANKED} #{ids.join(' UNION ')} ON CONFLICT DO NOTHING")
    end

    # Число домов по предкам у действующих домов из временной таблицы rows (house_ancestors) — в
    # HOUSE_COUNTS со знаком sign. До изменения (ids — изменяемые объекты) таблица создаётся, и в
    # неё записывается прежнее число домов изменяемых объектов: дельта может заменить их записи
    # новыми, без числа домов
    def count_houses(rows, sign: -1, ids: nil)
      if ids
        db_conn.exec("CREATE TEMP TABLE #{HOUSE_COUNTS} (object_id bigint, base integer, diff integer) ON COMMIT DROP")
        db_conn.exec_params("INSERT INTO #{HOUSE_COUNTS} SELECT object_id, house_count, 0 FROM #{qualified(:address_objects)} " \
                            "WHERE object_id = ANY($1::bigint[]) AND is_active AND is_actual", [ids])
      end
      db_conn.exec(<<~SQL)
        INSERT INTO #{HOUSE_COUNTS}
        SELECT u.object_id, NULL, #{sign} * count(*) FROM #{qualified(:houses)} h CROSS JOIN LATERAL (#{house_ancestors}) u(object_id)
        WHERE h.is_active AND h.id IN (SELECT id FROM #{rows}) GROUP BY u.object_id
      SQL
    end

    # Временная таблица id до конца транзакции (name — pg_temp.<имя>); values — начальные id
    def scope_table(name, values = [])
      db_conn.exec("DROP TABLE IF EXISTS #{name}")
      db_conn.exec("CREATE TEMP TABLE #{name} (id bigint PRIMARY KEY) ON COMMIT DROP")
      db_conn.exec_params("INSERT INTO #{name} SELECT unnest($1::bigint[])", [ids_param(values.uniq)])
      name
    end

    def reset_paths = hierarchies.flat_map { ["full_#{_1}_path = NULL", "full_#{_1}_path_tsv = NULL", "#{_1}_path_ids = NULL"] }.join(", ")

    def ids_param(object_ids) = Database.array(object_ids.map { Integer(_1) })

    # Батч: следующие batch_size записей с пустым путём. Путь по иерархии — названия
    # действующих актуальных адресных объектов из пути иерархии по порядку (дом из пути
    # отпадает сам: его object_id нет среди адресных объектов), у дома к нему добавляется
    # номер с типами («д. 14 к. 1 стр. 3»); path_ids — весь путь иерархии. Заполненные пути не
    # меняются. Возвращает последний id батча (курсор, NULL — записей больше нет), число
    # просмотренных и обновлённых записей. scope — временная таблица id (rebuild): батчи идут по
    # ней, а не по пустым путям всей таблицы
    def batch_sql(table, scope = nil)
      house  = table == :houses
      cursor = scope ? "s.id" : "t.id"
      paths =
        hierarchies.map do |hierarchy|
          <<~SQL
            #{hierarchy} AS (
              SELECT b.id, string_to_array(h.path, '.')::bigint[] AS ids, string_agg(ao.name || ' ' || ao.type_name, ', ' ORDER BY item.ord) AS path
              FROM batch b
              JOIN #{qualified(Configuration::HIERARCHY_TABLES[hierarchy])} h ON h.object_id = b.object_id AND h.is_active
              CROSS JOIN LATERAL unnest(string_to_array(h.path, '.')::bigint[]) WITH ORDINALITY AS item(object_id, ord)
              JOIN #{qualified(:address_objects)} ao ON ao.object_id = item.object_id AND ao.is_actual AND ao.is_active
              GROUP BY b.id, h.path
            ),
          SQL
        end

      <<~SQL
        WITH batch AS (
          SELECT t.id, t.object_id, #{house ? "#{HOUSE_NUMBER} AS number" : 'NULL AS number'}
          FROM #{scope ? "#{scope} s JOIN #{qualified(table)} t ON t.id = s.id" : "#{qualified(table)} t"}
          #{Schema.house_type_joins(schema, 't') if house}
          WHERE #{cursor} > $1#{" AND (#{empty_condition})" unless scope}
          ORDER BY #{cursor}
          LIMIT $2
        ),
        #{paths.join}
        paths AS (
          SELECT b.id, #{hierarchies.map { "#{_1}.path || COALESCE(', ' || b.number, '') AS #{_1}, #{_1}.ids AS #{_1}_ids" }.join(', ')}
          FROM batch b
          #{hierarchies.map { "LEFT JOIN #{_1} ON #{_1}.id = b.id" }.join("\n  ")}
        ),
        updated AS (
          UPDATE #{qualified(table)} t
          SET #{hierarchies.map { |h| update_columns(h) }.join(', ')}
          FROM paths p
          WHERE t.id = p.id AND (#{hierarchies.map { "p.#{_1} IS NOT NULL" }.join(' OR ')})
          RETURNING t.id
        )
        SELECT (SELECT max(id) FROM batch) AS last_id, (SELECT count(*) FROM batch) AS seen, (SELECT count(*) FROM updated) AS updated
      SQL
    end

    def update_columns(hierarchy)
      ["full_#{hierarchy}_path = COALESCE(t.full_#{hierarchy}_path, p.#{hierarchy})",
       "full_#{hierarchy}_path_tsv = COALESCE(t.full_#{hierarchy}_path_tsv, to_tsvector('russian', p.#{hierarchy}))",
       "#{hierarchy}_path_ids = COALESCE(t.#{hierarchy}_path_ids, p.#{hierarchy}_ids)"].join(", ")
    end

    # Ранжирование адресных объектов: число действующих домов в поддереве (по обеим
    # иерархиям, дом считается один раз) и признак административного центра субъекта
    # (CAPITAL_PARAM; не центр — NULL). Центр муниципального образования (параметр 23) признака
    # не даёт: он есть у сотен посёлков и поднимал бы их выше крупных улиц с тем же названием.
    # Пересчитывается при каждом build, переписываются только изменившиеся строки; затем
    # статистика для планировщика поиска. scope — временная таблица OBJECTID (rebuild): число
    # домов меняется на разницу из HOUSE_COUNTS, признак центра — только у объектов scope, без
    # VACUUM
    def update_ranks(scope: nil)
      logger.info "Ранжирование адресных объектов: число домов и административные центры"
      objects = qualified(:address_objects)
      db_conn.exec(scope ? house_count_change_sql(objects) : house_count_sql(objects))
      if table_exists?(:addr_obj_params)
        capital = "NULLIF(ao.object_id IN (SELECT object_id FROM #{qualified(:addr_obj_params)} " \
                  "WHERE type_id = #{CAPITAL_PARAM} AND lower(value) NOT IN ('0', 'false')), false)"
        db_conn.exec("UPDATE #{objects} ao SET is_capital = #{capital} WHERE ao.is_capital IS DISTINCT FROM #{capital}" \
                     "#{" AND ao.object_id IN (SELECT id FROM #{scope})" if scope}")
      end
      db_conn.exec("VACUUM (ANALYZE) #{objects}") unless scope
    end

    # Число действующих домов в поддереве каждого адресного объекта (без домов — NULL)
    def house_count_sql(objects)
      <<~SQL
        WITH c AS (
          SELECT u.object_id, count(*)::int AS count
          FROM #{qualified(:houses)} h CROSS JOIN LATERAL (#{house_ancestors}) u(object_id)
          WHERE h.is_active GROUP BY u.object_id
        )
        UPDATE #{objects} ao SET house_count = c.count
        FROM #{objects} a LEFT JOIN c ON c.object_id = a.object_id
        WHERE ao.id = a.id AND ao.house_count IS DISTINCT FROM c.count
      SQL
    end

    # Число домов после изменения: прежнее (записанное до него или текущее) плюс разница из
    # HOUSE_COUNTS; ноль — NULL, как у полного пересчёта
    def house_count_change_sql(objects)
      count = "NULLIF(COALESCE(c.base, ao.house_count, 0) + c.diff, 0)"
      <<~SQL
        WITH c AS (SELECT object_id, max(base) AS base, sum(diff) AS diff FROM #{HOUSE_COUNTS} GROUP BY object_id)
        UPDATE #{objects} ao SET house_count = #{count}
        FROM c WHERE ao.object_id = c.object_id AND ao.house_count IS DISTINCT FROM #{count}
      SQL
    end

    # Предки дома (h) по загруженным иерархиям без повторов: путь без самого дома; объекты
    # муниципального пути, которых нет в административном
    def house_ancestors
      paths = hierarchies.map { "h.#{_1}_path_ids[:cardinality(h.#{_1}_path_ids) - 1]" }
      return "SELECT unnest(#{paths[0]})" if paths.size == 1

      "SELECT unnest(#{paths[0]}) UNION ALL SELECT m FROM unnest(#{paths[1]}) m WHERE m <> ALL(COALESCE(#{paths[0]}, '{}'))"
    end

    def empty_condition = hierarchies.map { "full_#{_1}_path IS NULL" }.join(" OR ")

    def with_empty_paths_index(table)
      index = "idx_#{table}_empty_paths_tmp"
      db_conn.exec("CREATE INDEX IF NOT EXISTS #{Schema.quote(index)} ON #{qualified(table)} (id) WHERE #{empty_condition}")
      yield
    ensure
      db_conn.exec("DROP INDEX IF EXISTS #{qualified(index)}")
    end

    def vacuum(table)
      logger.info "VACUUM #{table}"
      db_conn.exec("VACUUM #{qualified(table)}")
    end

    # GIN-индексы по OBJECTID и tsvector путей; память на построение — import_maintenance_work_mem.
    # Индексы tsvector — признак построенных путей для Gar.available?
    def create_path_indexes(table)
      logger.info "Индексы путей: #{table}"
      db_conn.transaction do |conn|
        Database.set_work_memory(conn, "maintenance_work_mem")
        hierarchies.each do |hierarchy|
          create_index(conn, table, "#{hierarchy}_path_ids")
          create_index(conn, table, "full_#{hierarchy}_path_tsv", "WHERE is_active")
        end
      end
    end

    def create_index(conn, table, column, condition = nil)
      conn.exec("CREATE INDEX IF NOT EXISTS #{Schema.quote("idx_#{table}_#{column}")} ON #{qualified(table)} USING gin (#{column}) #{condition}")
    end

    def table_exists?(name) = Database.relation_exists?(db_conn, qualified(name))

    def qualified(name) = Schema.qualify(schema, name)
  end
end
