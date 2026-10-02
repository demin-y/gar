# frozen_string_literal: true

module Gar
  # Полные пути адресных объектов и домов по иерархиям: «Кировская обл, Киров г, Ленина ул, д. 10»
  # в full_adm_path/full_mun_path и их tsvector для полнотекстового поиска.
  #
  # Какие пути строить, решает состав схемы: строятся пути таблиц с путями (Schema, колонки
  # full_*_path) по загруженным иерархиям. Заполняются только пустые пути, по возрастанию id,
  # батчами — по одному запросу на батч, обе иерархии сразу. Поэтому прерванное построение
  # можно продолжить, а после очистки части путей — пересобрать только её.
  #
  #   Gar::PathBuilder.new(conn, schema: "gar_v20260116").build
  class PathBuilder
    include Loggable

    # Таблица после пакетных UPDATE растёт вдвое: VACUUM возвращает место под следующие батчи
    VACUUM_EVERY_N_BATCHES = 50

    attr_reader :db_conn, :schema

    def initialize(db_conn = nil, schema: Gar.configuration.database_schema)
      @db_conn = db_conn ? Database.adopt(db_conn) : Database.create_connection
      @schema  = schema
    end

    # Заполняет пустые пути и строит полнотекстовые индексы. on_progress — ->(done, total, stage):
    # просмотренные записи с пустым путём, stage = :paths. Возвращает число записей, у которых
    # заполнился хотя бы один путь; записи без строки в иерархии остаются пустыми.
    def build(batch_size: 25_000, on_progress: nil)
      tables = self.tables
      return 0 if tables.empty?

      hierarchies = self.hierarchies
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
        create_fulltext_indexes(table, hierarchies)
      end
      updated
    end

    # Таблицы с путями; без адресных объектов пути не строятся — они собираются из них
    def tables
      return [] if hierarchies.empty? || !table_exists?(:address_objects)

      Schema::REGIONAL.select { _1.derived.any? }.map(&:name).select { table_exists?(_1) }
    end

    # Загруженные иерархии
    def hierarchies = @hierarchies ||= Configuration::HIERARCHY_TABLES.select { table_exists?(_2) }.keys

    private

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
    # тип и номер. Заполненные пути не меняются. Возвращает последний id батча (курсор,
    # NULL — записей больше нет), число просмотренных и обновлённых записей
    def batch_sql(table, hierarchies)
      house  = table == :houses
      suffix = house ? "COALESCE(', ' || CASE WHEN b.house_num IS NOT NULL THEN concat_ws(' ', ht.short_name, b.house_num) END, '')" : "''"
      paths  =
        hierarchies.map do |hierarchy|
          <<~SQL
            #{hierarchy} AS (
              SELECT b.id, string_agg(ao.name || ' ' || ao.type_name, ', ' ORDER BY item.ord) AS path
              FROM batch b
              JOIN #{qualified(Configuration::HIERARCHY_TABLES[hierarchy])} h ON h.object_id = b.object_id AND h.is_active
              CROSS JOIN LATERAL unnest(string_to_array(h.path, '.')::bigint[]) WITH ORDINALITY AS item(object_id, ord)
              JOIN #{qualified(:address_objects)} ao ON ao.object_id = item.object_id AND ao.is_actual AND ao.is_active
              GROUP BY b.id
            ),
          SQL
        end

      <<~SQL
        WITH batch AS (
          SELECT id, object_id#{', house_num, house_type' if house} FROM #{qualified(table)}
          WHERE id > $1 AND (#{empty_condition(hierarchies)})
          ORDER BY id
          LIMIT $2
        ),
        #{paths.join}
        paths AS (
          SELECT b.id, #{hierarchies.map { "#{_1}.path || #{suffix} AS #{_1}" }.join(', ')}
          FROM batch b
          #{hierarchies.map { "LEFT JOIN #{_1} ON #{_1}.id = b.id" }.join("\n  ")}
          #{"LEFT JOIN #{qualified(:house_types)} ht ON ht.id = b.house_type" if house}
        ),
        updated AS (
          UPDATE #{qualified(table)} t
          SET #{hierarchies.map { |h| "full_#{h}_path = COALESCE(t.full_#{h}_path, p.#{h}), full_#{h}_path_tsv = COALESCE(t.full_#{h}_path_tsv, to_tsvector('russian', p.#{h}))" }.join(', ')}
          FROM paths p
          WHERE t.id = p.id AND (#{hierarchies.map { "p.#{_1} IS NOT NULL" }.join(' OR ')})
          RETURNING t.id
        )
        SELECT (SELECT max(id) FROM batch) AS last_id, (SELECT count(*) FROM batch) AS seen, (SELECT count(*) FROM updated) AS updated
      SQL
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

    # GIN-индексы по tsvector путей; память на построение — import_maintenance_work_mem
    def create_fulltext_indexes(table, hierarchies)
      logger.info "Полнотекстовые индексы путей: #{table}"
      memory = Gar.configuration.import_maintenance_work_mem
      db_conn.transaction do |conn|
        conn.exec("SET LOCAL maintenance_work_mem TO #{conn.escape_literal(memory)}") if memory
        hierarchies.each do |hierarchy|
          column = "full_#{hierarchy}_path_tsv"
          conn.exec("CREATE INDEX IF NOT EXISTS #{Schema.quote("idx_#{table}_#{column}")} ON #{qualified(table)} USING gin (#{column}) WHERE is_active")
        end
      end
    end

    def table_exists?(name)
      db_conn.exec_params("SELECT to_regclass($1)", [qualified(name)]).getvalue(0, 0)
    end

    def qualified(name) = "#{Schema.quote(schema)}.#{Schema.quote(name)}"
  end
end
