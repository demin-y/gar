# frozen_string_literal: true

module Gar
  # Полные пути адресных объектов и домов по иерархиям: «Кировская обл, Киров г, Ленина ул, д. 10»
  # в full_adm_path/full_mun_path и их tsvector для полнотекстового поиска.
  #
  # Какие пути строить, решает состав схемы: таблица address_objects или houses и иерархия
  # adm_hierarchy/mun_hierarchy должны быть загружены. Заполняются только пустые пути, по
  # возрастанию id, батчами — по одному запросу на батч. Поэтому прерванное построение можно
  # продолжить, а после очистки части путей — пересобрать только её.
  #
  #   Gar::PathBuilder.new(conn, schema: "gar_v20260116").build
  class PathBuilder
    include Loggable

    TABLES      = [:address_objects, :houses].freeze
    HIERARCHIES = [:adm, :mun].freeze
    # Таблица после пакетных UPDATE растёт вдвое: VACUUM возвращает место под следующие батчи
    VACUUM_EVERY_N_BATCHES = 50

    # Один проход: пути таблицы по одной иерархии
    Pass =
      Data.define(:table, :hierarchy) do
        def column = "full_#{hierarchy}_path"
        def to_s = "#{table}.#{column}"
      end

    attr_reader :db_conn, :schema

    def initialize(db_conn = nil, schema: Gar.configuration.database_schema)
      @db_conn = db_conn || Database.create_connection
      @schema  = schema
    end

    # Заполняет пустые пути всех загруженных таблиц и иерархий и строит полнотекстовые индексы.
    # on_progress — ->(done, total, stage): записи с заполненным путём, stage = :paths.
    # Возвращает число обновлённых записей.
    def build(batch_size: 25_000, on_progress: nil)
      passes = self.passes
      totals = passes.to_h { [_1, empty_paths(_1)] }
      total  = totals.values.sum
      done   = 0
      on_progress&.call(done, total, :paths)

      passes.each do |pass|
        logger.info "Заполнение #{pass}: #{totals[pass]} записей, батч #{batch_size}"
        done += fill(pass, batch_size) { |updated| on_progress&.call(done + updated, total, :paths) }
      end
      passes.map(&:table).uniq.each { create_fulltext_indexes(_1) }
      done
    end

    # Проходы по составу схемы; дома без адресных объектов не строятся — пути собираются из них
    def passes
      return [] unless table_exists?(:address_objects)

      TABLES.select { table_exists?(_1) }.product(HIERARCHIES.select { table_exists?(:"#{_1}_hierarchy") })
            .map { |table, hierarchy| Pass.new(table:, hierarchy:) }
    end

    private

    # Батчи по id с временным частичным индексом по пустым путям; блок получает число
    # обновлённых в этом проходе записей. Записи, путь которых не собрался (нет строки
    # в иерархии), остаются пустыми: курсор id их пропускает
    def fill(pass, batch_size)
      sql     = batch_sql(pass)
      last_id = 0
      updated = 0
      analyze(pass)
      with_empty_paths_index(pass) do
        (1..).each do |batch|
          row = db_conn.exec_params(sql, [last_id, batch_size])[0]
          break unless row["last_id"]

          last_id  = row["last_id"].to_i
          updated += row["updated"].to_i
          yield updated
          vacuum(pass) if (batch % VACUUM_EVERY_N_BATCHES).zero?
        end
      end
      logger.info "Заполнение #{pass} завершено: #{updated} записей"
      updated
    end

    # Батч: следующие batch_size записей с пустым путём, путь каждой — названия действующих
    # актуальных адресных объектов из пути иерархии по порядку. Дом из пути отпадает сам:
    # его object_id нет среди адресных объектов. Возвращает последний id батча (курсор) и
    # число обновлённых записей; батч без записей — last_id NULL
    def batch_sql(pass)
      target = table(pass.table)
      column = Schema.quote(pass.column)
      house  = pass.table == :houses
      path   = "string_agg(ao.name || ' ' || ao.type_name, ', ' ORDER BY item.ord)"
      path   = "#{path} || CASE WHEN t.house_num IS NULL THEN '' ELSE ', ' || concat_ws(' ', ht.short_name, t.house_num) END" if house

      <<~SQL
        WITH batch AS (
          SELECT id FROM #{target}
          WHERE id > $1 AND #{column} IS NULL
          ORDER BY id
          LIMIT $2
        ),
        paths AS (
          SELECT t.id, #{path} AS path
          FROM batch
          JOIN #{target} t ON t.id = batch.id
          JOIN #{table(:"#{pass.hierarchy}_hierarchy")} h ON h.object_id = t.object_id AND h.is_active
          CROSS JOIN LATERAL unnest(string_to_array(h.path, '.')::bigint[]) WITH ORDINALITY AS item(object_id, ord)
          JOIN #{table(:address_objects)} ao ON ao.object_id = item.object_id AND ao.is_actual AND ao.is_active
          #{"LEFT JOIN #{table(:house_types)} ht ON ht.id = t.house_type" if house}
          GROUP BY t.id#{', t.house_num, ht.short_name' if house}
        ),
        updated AS (
          UPDATE #{target} t
          SET #{column} = paths.path, #{Schema.quote("#{pass.column}_tsv")} = to_tsvector('russian', paths.path)
          FROM paths
          WHERE t.id = paths.id
          RETURNING t.id
        )
        SELECT (SELECT max(id) FROM batch) AS last_id, (SELECT count(*) FROM updated) AS updated
      SQL
    end

    def empty_paths(pass)
      db_conn.exec("SELECT count(*) FROM #{table(pass.table)} WHERE #{Schema.quote(pass.column)} IS NULL").getvalue(0, 0).to_i
    end

    # Статистика нужна планировщику для соединения с иерархией
    def analyze(pass)
      [pass.table, :"#{pass.hierarchy}_hierarchy", :address_objects].uniq.each { db_conn.exec("ANALYZE #{table(_1)}") }
    end

    def with_empty_paths_index(pass)
      index = Schema.quote("idx_#{pass.table}_#{pass.hierarchy}_empty_tmp")
      db_conn.exec("CREATE INDEX IF NOT EXISTS #{index} ON #{table(pass.table)} (id) WHERE #{Schema.quote(pass.column)} IS NULL")
      yield
    ensure
      db_conn.exec("DROP INDEX IF EXISTS #{Schema.quote(schema)}.#{index}")
    end

    def vacuum(pass)
      logger.info "VACUUM #{pass.table}"
      db_conn.exec("VACUUM #{table(pass.table)}")
    end

    def create_fulltext_indexes(table_name)
      logger.info "Полнотекстовые индексы путей: #{table_name}"
      HIERARCHIES.each do |hierarchy|
        index = Schema.quote("idx_#{table_name}_full_#{hierarchy}_path_tsv")
        db_conn.exec("CREATE INDEX IF NOT EXISTS #{index} ON #{table(table_name)} USING gin (full_#{hierarchy}_path_tsv) WHERE is_active")
      end
    end

    def table_exists?(name)
      db_conn.exec_params("SELECT to_regclass($1)", [table(name)]).getvalue(0, 0)
    end

    def table(name) = "#{Schema.quote(schema)}.#{Schema.quote(name)}"
  end
end
