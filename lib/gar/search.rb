# frozen_string_literal: true

require "mini_sql"
require_relative "utils"

module Gar
  class Search
    include Loggable

    attr_reader :db_conn, :schema_name, :db

    def initialize(db_conn = nil)
      @db_conn     = db_conn || Gar::Database.connection
      @schema_name = Gar.configuration.database_schema
      @db          = MiniSql::Connection.get(@db_conn, auto_encode_arrays: true)
    end

    # Полнотекстовый поиск в address_objects (двухфазный: сначала по name, потом по full_path)
    def search_address_objects(query, path_type: :adm, limit: 20, offset: 0, autocomplete: false)
      logger.debug "Поиск address_objects: query='#{query}', path_type=#{path_type}, limit=#{limit}"

      return [] if query.to_s.strip.empty?

      table_name   = Utils.full_table_name("address_objects", schema_name:)
      path_column  = path_type == :adm ? "full_adm_path" : "full_mun_path"
      tsv_column   = "#{path_column}_tsv"
      tsquery_func = autocomplete ? "to_tsquery" : "websearch_to_tsquery"
      search_query = autocomplete ? prepare_autocomplete_query(query) : query

      ctx = { table_name:, path_column:, tsv_column:, tsquery_func:, search_query: }

      # Фаза 1: поиск по name (использует существующий GIN-индекс idx_address_objects_fulltext)
      name_results = search_address_objects_by_name(ctx, limit:, offset:)
      return name_results if name_results.size >= limit

      # Фаза 2: дополнить результатами из full_path
      remaining   = limit - name_results.size
      path_offset = [offset - count_name_matches(ctx), 0].max

      path_results = search_address_objects_by_path(ctx, exclude_ids: name_results.map(&:id),
                                                    limit: remaining, offset: path_offset)

      name_results + path_results
    end

    # Полнотекстовый поиск в houses (stored tsvector)
    def search_houses(query, path_type: :adm, limit: 20, offset: 0, autocomplete: false)
      logger.debug "Поиск houses: query='#{query}', path_type=#{path_type}, limit=#{limit}"

      return [] if query.to_s.strip.empty?

      path_column  = path_type == :mun ? "full_mun_path" : "full_adm_path"
      tsv_column   = "#{path_column}_tsv"
      table_name   = Utils.full_table_name("houses", schema_name:)
      tsquery_func = autocomplete ? "to_tsquery" : "websearch_to_tsquery"
      search_query = autocomplete ? prepare_autocomplete_query(query) : query

      db.query(<<-SQL, search_query:, limit:, offset:)
        SELECT
          h.id,
          h.object_id,
          h.object_guid,
          h.house_num,
          ht.short_name as house_type,
          h.#{path_column},
          ts_rank_cd(h.#{tsv_column}, #{tsquery_func}('russian', :search_query)) as rank
        FROM #{table_name} h
        LEFT JOIN #{Utils.full_table_name('house_types', schema_name:)} ht ON ht.id = h.house_type
        WHERE h.is_active = true
          AND h.#{tsv_column} @@ #{tsquery_func}('russian', :search_query)
        ORDER BY rank DESC, h.house_num
        LIMIT :limit OFFSET :offset
      SQL
    end

    # Каскадный поиск address_objects по иерархии (прямые дети)
    def find_address_objects(parent_guid: nil, path_type: :adm, level: nil, limit: 50, offset: 0)
      hierarchy_table     = path_type == :adm ? "adm_hierarchy" : "mun_hierarchy"
      hierarchy_full_name = Utils.full_table_name(hierarchy_table, schema_name:)
      ao_table_name       = Utils.full_table_name("address_objects", schema_name:)

      if parent_guid.nil?
        # Поиск регионов (уровень 1)
        return db.query(<<-SQL, limit:, offset:)
          SELECT DISTINCT
            ao.id,
            ao.object_id,
            ao.object_guid,
            ao.name,
            ao.type_name,
            ao.level,
            ao.full_adm_path,
            ao.full_mun_path
          FROM #{ao_table_name} ao
          WHERE ao.is_active = true AND ao.level = 1
          ORDER BY ao.name
          LIMIT :limit OFFSET :offset
        SQL
      end

      # Поиск прямых детей по parent_obj_id
      level_condition = level ? "AND ao.level = :level" : ""

      db.query(<<-SQL, parent_guid:, level:, limit:, offset:)
        SELECT DISTINCT
          ao.id,
          ao.object_id,
          ao.object_guid,
          ao.name,
          ao.type_name,
          ao.level,
          ao.full_adm_path,
          ao.full_mun_path
        FROM #{hierarchy_full_name} h
        JOIN #{ao_table_name} ao ON ao.object_id = h.object_id
        WHERE h.is_active = true
          AND h.parent_obj_id = (
            SELECT object_id FROM #{ao_table_name} WHERE object_guid = :parent_guid AND is_active = true LIMIT 1
          )
          AND ao.is_active = true
          #{level_condition}
        ORDER BY ao.level, ao.name
        LIMIT :limit OFFSET :offset
      SQL
    end

    # Поиск домов по parent_guid (прямые дети)
    def find_houses(parent_guid, path_type: :adm, limit: 100, offset: 0)
      hierarchy_table     = path_type == :mun ? "mun_hierarchy" : "adm_hierarchy"
      hierarchy_full_name = Utils.full_table_name(hierarchy_table, schema_name:)
      houses_table_name   = Utils.full_table_name("houses", schema_name:)
      ht_table_name       = Utils.full_table_name("house_types", schema_name:)
      ao_table_name       = Utils.full_table_name("address_objects", schema_name:)

      db.query(<<-SQL, parent_guid:, limit:, offset:)
        SELECT
          h.id,
          h.object_id,
          h.object_guid,
          h.house_num,
          ht.short_name as house_type,
          h.full_adm_path,
          h.full_mun_path
        FROM #{hierarchy_full_name} hier
        JOIN #{houses_table_name} h ON h.object_id = hier.object_id
        LEFT JOIN #{ht_table_name} ht ON ht.id = h.house_type
        WHERE hier.parent_obj_id = (
          SELECT object_id FROM #{ao_table_name}
          WHERE object_guid = :parent_guid AND is_active = true LIMIT 1
        )
          AND hier.is_active = true
          AND h.is_active = true
        ORDER BY h.house_num
        LIMIT :limit OFFSET :offset
      SQL
    end

    def find_address_object_by_guid(guid, path_type: :adm)
      full_table_name = Utils.full_table_name("address_objects", schema_name:)
      path_column = path_type == :adm ? "full_adm_path" : "full_mun_path"

      db.query(<<-SQL, guid:).first
        SELECT
          id,
          object_id,
          object_guid,
          name,
          type_name,
          level,
          #{path_column}
        FROM #{full_table_name}
        WHERE object_guid = :guid AND is_active = true
        LIMIT 1
      SQL
    end

    def find_house_by_guid(guid, path_type: :adm)
      houses_table = Utils.full_table_name("houses", schema_name:)
      ht_table     = Utils.full_table_name("house_types", schema_name:)
      path_column  = path_type == :adm ? "full_adm_path" : "full_mun_path"

      db.query(<<-SQL, guid:).first
        SELECT
          h.id,
          h.object_id,
          h.object_guid,
          h.house_num,
          ht.short_name as house_type,
          h.#{path_column}
        FROM #{houses_table} h
        LEFT JOIN #{ht_table} ht ON ht.id = h.house_type
        WHERE h.object_guid = :guid AND h.is_active = true
        LIMIT 1
      SQL
    end

    private

    # Фаза 1: поиск по name || type_name (использует GIN-индекс idx_address_objects_fulltext)
    def search_address_objects_by_name(ctx, limit:, offset:)
      db.query(<<-SQL, search_query: ctx[:search_query], limit:, offset:)
        SELECT
          ao.id,
          ao.object_id,
          ao.object_guid,
          ao.name,
          ao.type_name,
          ao.level,
          ao.#{ctx[:path_column]},
          ts_rank_cd(
            to_tsvector('russian', ao.name || ' ' || ao.type_name),
            #{ctx[:tsquery_func]}('russian', :search_query)
          ) as rank
        FROM #{ctx[:table_name]} ao
        WHERE ao.is_active = true
          AND to_tsvector('russian', ao.name || ' ' || ao.type_name) @@ #{ctx[:tsquery_func]}('russian', :search_query)
        ORDER BY rank DESC,
          CASE ao.level WHEN 1 THEN 1 WHEN 2 THEN 2 WHEN 5 THEN 3 WHEN 6 THEN 4 WHEN 8 THEN 5 ELSE 6 END,
          ao.name
        LIMIT :limit OFFSET :offset
      SQL
    end

    # Фаза 2: поиск по full_path через stored tsvector
    def search_address_objects_by_path(ctx, exclude_ids:, limit:, offset:)
      exclude_condition = exclude_ids.empty? ? "" : "AND ao.id NOT IN (#{exclude_ids.join(', ')})"

      db.query(<<-SQL, search_query: ctx[:search_query], limit:, offset:)
        SELECT
          ao.id,
          ao.object_id,
          ao.object_guid,
          ao.name,
          ao.type_name,
          ao.level,
          ao.#{ctx[:path_column]},
          ts_rank_cd(ao.#{ctx[:tsv_column]}, #{ctx[:tsquery_func]}('russian', :search_query)) as rank
        FROM #{ctx[:table_name]} ao
        WHERE ao.is_active = true
          AND ao.#{ctx[:tsv_column]} @@ #{ctx[:tsquery_func]}('russian', :search_query)
          #{exclude_condition}
        ORDER BY rank DESC,
          CASE ao.level WHEN 1 THEN 1 WHEN 2 THEN 2 WHEN 5 THEN 3 WHEN 6 THEN 4 WHEN 8 THEN 5 ELSE 6 END,
          ao.name
        LIMIT :limit OFFSET :offset
      SQL
    end

    def count_name_matches(ctx)
      db.query_single(<<-SQL, search_query: ctx[:search_query]).first || 0
        SELECT COUNT(*)
        FROM #{ctx[:table_name]} ao
        WHERE ao.is_active = true
          AND to_tsvector('russian', ao.name || ' ' || ao.type_name) @@ #{ctx[:tsquery_func]}('russian', :search_query)
      SQL
    end

    # Подготовка запроса для autocomplete: добавляет :* к последнему слову
    def prepare_autocomplete_query(query)
      sanitized = query.to_s.strip.gsub(/[!|&:*()\\'"<>]/, " ")
      words = sanitized.split(/\s+/).reject(&:empty?)
      return "" if words.empty?

      # К последнему слову добавляем :* для prefix-поиска
      words[-1] = "#{words[-1]}:*"
      words.join(" & ")
    end
  end
end
