# frozen_string_literal: true

require_relative "utils"

module Gar
  class FullPathBuilder
    include Loggable

    VACUUM_EVERY_N_BATCHES = 50

    attr_reader :db, :schema_name

    def initialize(db_conn = nil, schema_name: Gar.configuration.database_schema)
      @db          = db_conn.is_a?(Database) ? db_conn : Database.new(db_conn)
      @schema_name = schema_name
    end

    def db_conn
      @db.conn
    end

    def update_address_objects_paths
      table_name      = "address_objects"
      full_table_name = Utils.full_table_name(table_name, schema_name:)

      unless table_exists?(full_table_name)
        logger.info "Таблица #{full_table_name} не найдена"
        return
      end

      add_column_if_not_exists(full_table_name, "full_adm_path")
      add_column_if_not_exists(full_table_name, "full_mun_path")
      add_column_if_not_exists(full_table_name, "full_adm_path_tsv", "TSVECTOR")
      add_column_if_not_exists(full_table_name, "full_mun_path_tsv", "TSVECTOR")
      populate_address_objects_paths
      create_fulltext_indexes_for_table(table_name)
    end

    def update_houses_paths
      table_name      = "houses"
      full_table_name = Utils.full_table_name(table_name, schema_name:)

      unless table_exists?(full_table_name)
        logger.info "Таблица #{full_table_name} не найдена"
        return
      end

      add_column_if_not_exists(full_table_name, "full_adm_path")
      add_column_if_not_exists(full_table_name, "full_mun_path")
      add_column_if_not_exists(full_table_name, "full_adm_path_tsv", "TSVECTOR")
      add_column_if_not_exists(full_table_name, "full_mun_path_tsv", "TSVECTOR")
      populate_houses_paths
      create_fulltext_indexes_for_table(table_name)
    end

    # Заполняет колонки для всех адресных объектов по загруженным иерархиям
    def populate_address_objects_paths(batch_size: 50_000)
      populate_address_objects_adm_paths(batch_size:) if hierarchy_loaded?(:adm)
      populate_address_objects_mun_paths(batch_size:) if hierarchy_loaded?(:mun)
    end

    # Заполняет колонки для всех домов по загруженным иерархиям
    def populate_houses_paths(batch_size: 25_000)
      populate_houses_adm_paths(batch_size:) if hierarchy_loaded?(:adm)
      populate_houses_mun_paths(batch_size:) if hierarchy_loaded?(:mun)
    end

    # Заполняет только adm_path для address_objects
    def populate_address_objects_adm_paths(batch_size: 50_000)
      populate_paths_for_table(
        table_name:  "address_objects",
        path_type:   :adm,
        sql_builder: ->(opts) { address_objects_adm_batch_sql(**opts) },
        batch_size:
      )
    end

    # Заполняет только mun_path для address_objects
    def populate_address_objects_mun_paths(batch_size: 50_000)
      populate_paths_for_table(
        table_name:  "address_objects",
        path_type:   :mun,
        sql_builder: ->(opts) { address_objects_mun_batch_sql(**opts) },
        batch_size:
      )
    end

    # Заполняет только adm_path для houses
    def populate_houses_adm_paths(batch_size: 25_000)
      populate_paths_for_table(
        table_name:  "houses",
        path_type:   :adm,
        sql_builder: ->(opts) { houses_adm_batch_sql(**opts) },
        batch_size:
      )
    end

    # Заполняет только mun_path для houses
    def populate_houses_mun_paths(batch_size: 25_000)
      populate_paths_for_table(
        table_name:  "houses",
        path_type:   :mun,
        sql_builder: ->(opts) { houses_mun_batch_sql(**opts) },
        batch_size:
      )
    end

    private

    # SQL для батчевого обновления только adm_path для address_objects
    def address_objects_adm_batch_sql(batch_size:, last_id: 0)
      full_table_name     = Utils.full_table_name("address_objects", schema_name:)
      adm_hierarchy_table = Utils.full_table_name("adm_hierarchy", schema_name:)

      <<-SQL
        WITH batch_ids AS (
          SELECT id FROM #{full_table_name}
          WHERE id > #{last_id}
            AND full_adm_path IS NULL
          ORDER BY id
          LIMIT #{batch_size}
        ),
        adm_paths AS (
          SELECT
            ao_main.id,
            string_agg(ao.name || ' ' || ao.type_name, ', ' ORDER BY path_elem.ord) AS full_path
          FROM #{full_table_name} ao_main
          INNER JOIN batch_ids ON batch_ids.id = ao_main.id
          INNER JOIN #{adm_hierarchy_table} ah ON ah.object_id = ao_main.object_id AND ah.is_active = true
          CROSS JOIN LATERAL unnest(regexp_split_to_array(ah.path, '\\.')::bigint[]) WITH ORDINALITY AS path_elem(object_id, ord)
          INNER JOIN #{full_table_name} ao ON ao.object_id = path_elem.object_id AND ao.is_active = true
          GROUP BY ao_main.id
        )
        UPDATE #{full_table_name} ao
        SET
          full_adm_path     = adm_paths.full_path,
          full_adm_path_tsv = to_tsvector('russian', COALESCE(adm_paths.full_path, ''))
        FROM adm_paths
        WHERE ao.id = adm_paths.id
        RETURNING ao.id
      SQL
    end

    # SQL для батчевого обновления только mun_path для address_objects
    def address_objects_mun_batch_sql(batch_size:, last_id: 0)
      full_table_name     = Utils.full_table_name("address_objects", schema_name:)
      mun_hierarchy_table = Utils.full_table_name("mun_hierarchy", schema_name:)

      <<-SQL
        WITH batch_ids AS (
          SELECT id FROM #{full_table_name}
          WHERE id > #{last_id}
            AND full_mun_path IS NULL
          ORDER BY id
          LIMIT #{batch_size}
        ),
        mun_paths AS (
          SELECT
            ao_main.id,
            string_agg(ao.name || ' ' || ao.type_name, ', ' ORDER BY path_elem.ord) AS full_path
          FROM #{full_table_name} ao_main
          INNER JOIN batch_ids ON batch_ids.id = ao_main.id
          INNER JOIN #{mun_hierarchy_table} mh ON mh.object_id = ao_main.object_id AND mh.is_active = true
          CROSS JOIN LATERAL unnest(regexp_split_to_array(mh.path, '\\.')::bigint[]) WITH ORDINALITY AS path_elem(object_id, ord)
          INNER JOIN #{full_table_name} ao ON ao.object_id = path_elem.object_id AND ao.is_active = true
          GROUP BY ao_main.id
        )
        UPDATE #{full_table_name} ao
        SET
          full_mun_path     = mun_paths.full_path,
          full_mun_path_tsv = to_tsvector('russian', COALESCE(mun_paths.full_path, ''))
        FROM mun_paths
        WHERE ao.id = mun_paths.id
        RETURNING ao.id
      SQL
    end

    # SQL для батчевого обновления только adm_path для houses
    def houses_adm_batch_sql(batch_size:, last_id: 0)
      houses_table          = Utils.full_table_name("houses", schema_name:)
      house_types_table     = Utils.full_table_name("house_types", schema_name:)
      adm_hierarchy_table   = Utils.full_table_name("adm_hierarchy", schema_name:)
      address_objects_table = Utils.full_table_name("address_objects", schema_name:)

      <<-SQL
        WITH batch_ids AS (
          SELECT id FROM #{houses_table}
          WHERE id > #{last_id}
            AND full_adm_path IS NULL
          ORDER BY id
          LIMIT #{batch_size}
        ),
        adm_paths AS (
          SELECT
            h_main.id,
            string_agg(ao.name || ' ' || ao.type_name, ', ' ORDER BY path_elem.ord) || ', ' || COALESCE(ht.short_name || ' ', '') || h_main.house_num AS full_path
          FROM #{houses_table} h_main
          INNER JOIN batch_ids ON batch_ids.id = h_main.id
          INNER JOIN #{adm_hierarchy_table} ah ON ah.object_id = h_main.object_id AND ah.is_active = true
          CROSS JOIN LATERAL unnest(regexp_split_to_array(ah.path, '\\.')::bigint[]) WITH ORDINALITY AS path_elem(object_id, ord)
          INNER JOIN #{address_objects_table} ao ON ao.object_id = path_elem.object_id AND ao.is_active = true
          LEFT JOIN #{house_types_table} ht ON ht.id = h_main.house_type
          GROUP BY h_main.id, h_main.house_num, ht.short_name
        )
        UPDATE #{houses_table} h
        SET
          full_adm_path     = adm_paths.full_path,
          full_adm_path_tsv = to_tsvector('russian', COALESCE(adm_paths.full_path, ''))
        FROM adm_paths
        WHERE h.id = adm_paths.id
        RETURNING h.id
      SQL
    end

    # SQL для батчевого обновления только mun_path для houses
    def houses_mun_batch_sql(batch_size:, last_id: 0)
      houses_table          = Utils.full_table_name("houses", schema_name:)
      house_types_table     = Utils.full_table_name("house_types", schema_name:)
      mun_hierarchy_table   = Utils.full_table_name("mun_hierarchy", schema_name:)
      address_objects_table = Utils.full_table_name("address_objects", schema_name:)

      <<-SQL
        WITH batch_ids AS (
          SELECT id FROM #{houses_table}
          WHERE id > #{last_id}
            AND full_mun_path IS NULL
          ORDER BY id
          LIMIT #{batch_size}
        ),
        mun_paths AS (
          SELECT
            h_main.id,
            string_agg(ao.name || ' ' || ao.type_name, ', ' ORDER BY path_elem.ord) || ', ' || COALESCE(ht.short_name || ' ', '') || h_main.house_num AS full_path
          FROM #{houses_table} h_main
          INNER JOIN batch_ids ON batch_ids.id = h_main.id
          INNER JOIN #{mun_hierarchy_table} mh ON mh.object_id = h_main.object_id AND mh.is_active = true
          CROSS JOIN LATERAL unnest(regexp_split_to_array(mh.path, '\\.')::bigint[]) WITH ORDINALITY AS path_elem(object_id, ord)
          INNER JOIN #{address_objects_table} ao ON ao.object_id = path_elem.object_id AND ao.is_active = true
          LEFT JOIN #{house_types_table} ht ON ht.id = h_main.house_type
          GROUP BY h_main.id, h_main.house_num, ht.short_name
        )
        UPDATE #{houses_table} h
        SET
          full_mun_path     = mun_paths.full_path,
          full_mun_path_tsv = to_tsvector('russian', COALESCE(mun_paths.full_path, ''))
        FROM mun_paths
        WHERE h.id = mun_paths.id
        RETURNING h.id
      SQL
    end

    # Общий метод для батчевого заполнения путей с cursor-based пагинацией
    def populate_paths_for_table(table_name:, path_type:, sql_builder:, batch_size: 10_000)
      last_id         = 0
      processed       = 0
      batch_number    = 0
      full_table_name = Utils.full_table_name(table_name, schema_name:)

      # Определяем условия для конкретного типа пути
      null_condition, path_column =
        case path_type
        when :adm
          ["full_adm_path IS NULL", "full_adm_path"]
        when :mun
          ["full_mun_path IS NULL", "full_mun_path"]
        end

      total = db_conn.exec("SELECT COUNT(*) FROM #{full_table_name} WHERE #{null_condition}").getvalue(0, 0).to_i

      logger.info "Заполнение #{path_column} для #{table_name} (#{total} записей, батч: #{batch_size})"

      optimize_session(table_name, path_type:)
      create_null_paths_index(table_name, path_type:)

      begin
        loop do
          batch_max = db_conn.exec(<<-SQL).getvalue(0, 0)
            SELECT MAX(id) FROM (
              SELECT id FROM #{full_table_name}
              WHERE id > #{last_id}
                AND #{null_condition}
              ORDER BY id LIMIT #{batch_size}
            ) t
          SQL

          break if batch_max.nil?

          sql = sql_builder.call(batch_size:, last_id:)
          result = db_conn.exec(sql)

          last_id       = batch_max.to_i
          batch_number += 1
          processed    += result.cmd_tuples
          percentage    = total.positive? ? (processed.to_f / total * 100).round(2) : 0
          logger.info "Обработано: #{processed}/#{total} (#{percentage}%)"

          vacuum_if_needed(full_table_name, batch_number)
        end
      ensure
        drop_null_paths_index(table_name, path_type:)
      end

      logger.info "Заполнение #{path_column} для #{table_name} завершено"
    end

    # Иерархию можно не загружать (config.hierarchies): пути по ней тогда не строятся
    def hierarchy_loaded?(type)
      table_exists?(Utils.full_table_name("#{type}_hierarchy", schema_name:)).tap do |loaded|
        logger.info "Таблицы #{type}_hierarchy нет: пути #{type} не строятся" unless loaded
      end
    end

    def add_column_if_not_exists(full_table_name, column_name, column_type = "TEXT")
      db_conn.exec("ALTER TABLE #{full_table_name} ADD COLUMN IF NOT EXISTS #{column_name} #{column_type}")
    end

    def create_fulltext_indexes_for_table(table_name)
      full_table_name = Utils.full_table_name(table_name, schema_name:)
      logger.info "Создание полнотекстовых индексов для #{table_name}..."

      db_conn.exec(<<-SQL)
        CREATE INDEX IF NOT EXISTS idx_#{table_name}_full_adm_path_tsv
          ON #{full_table_name} USING gin(full_adm_path_tsv) WHERE is_active = true;
        CREATE INDEX IF NOT EXISTS idx_#{table_name}_full_mun_path_tsv
          ON #{full_table_name} USING gin(full_mun_path_tsv) WHERE is_active = true;
      SQL
    end

    def optimize_session(table_name, path_type:)
      full_table_name     = Utils.full_table_name(table_name, schema_name:)
      adm_hierarchy_table = Utils.full_table_name("adm_hierarchy", schema_name:)
      mun_hierarchy_table = Utils.full_table_name("mun_hierarchy", schema_name:)

      logger.info "Обновление статистики таблиц..."
      case path_type
      when :adm
        db_conn.exec("ANALYZE #{adm_hierarchy_table}")
      when :mun
        db_conn.exec("ANALYZE #{mun_hierarchy_table}")
      end
      db_conn.exec("ANALYZE #{full_table_name}")
    end

    def create_null_paths_index(table_name, path_type:)
      full_table_name = Utils.full_table_name(table_name, schema_name:)
      logger.info "Создание временного индекса для #{table_name} (#{path_type})..."

      case path_type
      when :adm
        db_conn.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS idx_#{table_name}_adm_null_tmp
          ON #{full_table_name} (id)
          WHERE full_adm_path IS NULL
        SQL
      when :mun
        db_conn.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS idx_#{table_name}_mun_null_tmp
          ON #{full_table_name} (id)
          WHERE full_mun_path IS NULL
        SQL
      end
    end

    def drop_null_paths_index(table_name, path_type:)
      idx_name =
        case path_type
        when :adm
          Utils.full_table_name("idx_#{table_name}_adm_null_tmp", schema_name:)
        when :mun
          Utils.full_table_name("idx_#{table_name}_mun_null_tmp", schema_name:)
        end
      db_conn.exec("DROP INDEX IF EXISTS #{idx_name}")
    end

    def vacuum_if_needed(full_table_name, batch_number)
      return unless (batch_number % VACUUM_EVERY_N_BATCHES).zero?

      logger.info "VACUUM #{full_table_name}..."
      db_conn.exec("VACUUM #{full_table_name}")
    end

    def table_exists?(full_table_name)
      if full_table_name.include?(".")
        schema, table = full_table_name.split(".", 2)
      else
        schema = db_conn.exec("SELECT current_schema()").getvalue(0, 0)
        table = full_table_name
      end

      result = db_conn.exec_params(
        "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2 LIMIT 1",
        [schema, table]
      )
      result.ntuples.positive?
    end
  end
end
