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
    def build(batch_size: 25_000, on_progress: nil)
      Database.with_lock(db_conn, "Построение путей схемы #{schema}") { build_paths(batch_size, on_progress) }
    end

    # Очищает пути объектов object_ids (OBJECTID) и всех их потомков — записей, в пути которых
    # они есть, — чтобы build пересобрал их: после переименования, переноса в иерархии или
    # удаления объекта. Возвращает число очищенных записей
    def invalidate(object_ids)
      return 0 if hierarchies.empty?

      ids   = Database.array(object_ids.map { Integer(_1) })
      reset = hierarchies.flat_map { ["full_#{_1}_path = NULL", "full_#{_1}_path_tsv = NULL", "#{_1}_path_ids = NULL"] }.join(", ")
      found = ["object_id = ANY($1::bigint[])", *hierarchies.map { "#{_1}_path_ids && $1::bigint[]" }].join(" OR ")

      Database.with_lock(db_conn, "Очистка путей схемы #{schema}") do
        tables.sum { db_conn.exec_params("UPDATE #{qualified(_1)} SET #{reset} WHERE #{found}", [ids]).cmd_tuples }
      end
    end

    # Таблицы с путями
    def tables = Schema::REGIONAL.select(&:paths?).map(&:name).select { table_exists?(_1) }

    # Загруженные иерархии
    def hierarchies = @hierarchies ||= Configuration::HIERARCHY_TABLES.select { table_exists?(_2) }.keys

    private

    def build_paths(batch_size, on_progress)
      raise ConfigurationError, "В схеме #{schema} нет адресных объектов: пути строить не из чего" unless table_exists?(:address_objects)
      raise ImportError, "Импорт в схему #{schema} не завершён: пути строятся после него" if Meta.read(db_conn, schema)&.status == "importing"
      raise ConfigurationError, "В схеме #{schema} нет ни одной иерархии (adm_hierarchy, mun_hierarchy)" if hierarchies.empty?

      tables      = self.tables
      pending     = tables.to_h { [_1, db_conn.exec("SELECT count(*) FROM #{qualified(_1)} WHERE #{empty_condition(hierarchies)}").getvalue(0, 0).to_i] }
      total       = pending.values.sum
      done        = 0
      updated     = 0
      on_progress&.call(done, total, :paths)
      [*tables, *hierarchies.map { Configuration::HIERARCHY_TABLES[_1] }].uniq.each { db_conn.exec("ANALYZE #{qualified(_1)}") }

      tables.each do |table|
        logger.info "Заполнение путей #{table} (#{hierarchies.join(', ')}): #{pending[table]} записей, батч #{batch_size}"
        updated += fill(table, hierarchies, batch_size) { on_progress&.call(done + _1, total, :paths) }
        done    += pending[table]
        create_path_indexes(table, hierarchies)
      end
      update_ranks if tables.include?(:houses)
      Meta.update(db_conn, schema, "ready")
      updated
    end

    # Батчи по id с временным частичным индексом по пустым путям; блок получает число
    # просмотренных записей. Курсор id пропускает записи, путь которых не собрался
    def fill(table, hierarchies, batch_size)
      sql     = batch_sql(table, hierarchies)
      last_id = 0
      seen    = 0
      updated = 0
      with_empty_paths_index(table, hierarchies) do
        (1..).each do |batch|
          row = db_conn.exec_params(sql, [last_id, batch_size])[0]
          break unless row["last_id"]

          last_id  = row["last_id"].to_i
          seen    += row["seen"].to_i
          updated += row["updated"].to_i
          yield seen
          vacuum(table) if (batch % VACUUM_EVERY_N_BATCHES).zero?
        end
      end
      logger.info "Заполнение путей #{table} завершено: #{updated} записей"
      updated
    end

    # Батч: следующие batch_size записей с пустым путём. Путь по иерархии — названия
    # действующих актуальных адресных объектов из пути иерархии по порядку (дом из пути
    # отпадает сам: его object_id нет среди адресных объектов), у дома к нему добавляется
    # номер с типами («д. 14 к. 1 стр. 3»); path_ids — весь путь иерархии. Заполненные пути не
    # меняются. Возвращает последний id батча (курсор, NULL — записей больше нет), число
    # просмотренных и обновлённых записей
    def batch_sql(table, hierarchies)
      house = table == :houses
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
          FROM #{qualified(table)} t
          #{house_type_joins if house}
          WHERE t.id > $1 AND (#{empty_condition(hierarchies)})
          ORDER BY t.id
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

    def house_type_joins
      "LEFT JOIN #{qualified(:house_types)} ht ON ht.id = t.house_type " \
        "LEFT JOIN #{qualified(:add_house_types)} a1 ON a1.id = t.add_type1 " \
        "LEFT JOIN #{qualified(:add_house_types)} a2 ON a2.id = t.add_type2"
    end

    def update_columns(hierarchy)
      ["full_#{hierarchy}_path = COALESCE(t.full_#{hierarchy}_path, p.#{hierarchy})",
       "full_#{hierarchy}_path_tsv = COALESCE(t.full_#{hierarchy}_path_tsv, to_tsvector('russian', p.#{hierarchy}))",
       "#{hierarchy}_path_ids = COALESCE(t.#{hierarchy}_path_ids, p.#{hierarchy}_ids)"].join(", ")
    end

    # Ранжирование адресных объектов: число действующих домов в поддереве (по обеим
    # иерархиям, дом считается один раз) и признак административного центра (параметры 22, 23;
    # не центр — NULL). Пересчитывается при каждом build, переписываются только изменившиеся
    # строки; затем статистика для планировщика поиска
    def update_ranks
      logger.info "Ранжирование адресных объектов: число домов и административные центры"
      objects = qualified(:address_objects)
      db_conn.exec(<<~SQL)
        WITH c AS (
          SELECT u.object_id, count(*)::int AS count
          FROM #{qualified(:houses)} h CROSS JOIN LATERAL (#{house_ancestors}) u(object_id)
          WHERE h.is_active GROUP BY u.object_id
        )
        UPDATE #{objects} ao SET house_count = c.count
        FROM #{objects} a LEFT JOIN c ON c.object_id = a.object_id
        WHERE ao.id = a.id AND ao.house_count IS DISTINCT FROM c.count
      SQL
      if table_exists?(:addr_obj_params)
        capital = "NULLIF(ao.object_id IN (SELECT object_id FROM #{qualified(:addr_obj_params)} " \
                  "WHERE type_id IN (22, 23) AND lower(value) NOT IN ('0', 'false')), false)"
        db_conn.exec("UPDATE #{objects} ao SET is_capital = #{capital} WHERE ao.is_capital IS DISTINCT FROM #{capital}")
      end
      db_conn.exec("VACUUM (ANALYZE) #{objects}")
    end

    # Предки дома (h) по загруженным иерархиям без повторов: путь без самого дома; объекты
    # муниципального пути, которых нет в административном
    def house_ancestors
      paths = hierarchies.map { "h.#{_1}_path_ids[:cardinality(h.#{_1}_path_ids) - 1]" }
      return "SELECT unnest(#{paths[0]})" if paths.size == 1

      "SELECT unnest(#{paths[0]}) UNION ALL SELECT m FROM unnest(#{paths[1]}) m WHERE m <> ALL(COALESCE(#{paths[0]}, '{}'))"
    end

    def empty_condition(hierarchies) = hierarchies.map { "full_#{_1}_path IS NULL" }.join(" OR ")

    def with_empty_paths_index(table, hierarchies)
      index = "idx_#{table}_empty_paths_tmp"
      db_conn.exec("CREATE INDEX IF NOT EXISTS #{Schema.quote(index)} ON #{qualified(table)} (id) WHERE #{empty_condition(hierarchies)}")
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
    def create_path_indexes(table, hierarchies)
      logger.info "Индексы путей: #{table}"
      memory = Gar.configuration.import_maintenance_work_mem
      db_conn.transaction do |conn|
        conn.exec("SET LOCAL maintenance_work_mem TO #{conn.escape_literal(memory)}") if memory
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

    def qualified(name) = "#{Schema.quote(schema)}.#{Schema.quote(name)}"
  end
end
