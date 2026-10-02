# frozen_string_literal: true

module Gar
  # Поиск по текущей схеме ГАР (config.database_schema). Результаты — AddressObject и House.
  #
  # Без явного соединения каждый вызов берёт соединение из пула (Gar.with_connection) только
  # на время запроса, поэтому один объект Search можно делить между потоками. Недоступная
  # база или statement_timeout — Gar::UnavailableError. Если загружен ActiveSupport, каждый
  # вызов публикует событие search.gar (метод, запрос, число результатов).
  #
  # path_type — иерархия: :adm (административная) или :mun (муниципальная). Если её нет в
  # схеме (импорт с config.hierarchies без неё), поиск по ней бросает ConfigurationError, а не
  # отвечает пустым списком.
  class Search
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # Регионы, затем районы, города, населённые пункты и улицы
    LEVEL_ORDER = "array_position(ARRAY[1, 2, 5, 6, 8], ao.level)"

    attr_reader :db_conn, :schema

    # db_conn — своё соединение вместо пула (его закрывает вызывающий)
    def initialize(db_conn = nil, schema: Gar.configuration.database_schema)
      @db_conn = db_conn
      @schema  = schema
    end

    # Полнотекстовый поиск адресных объектов: сначала совпадения по названию, затем — только
    # по полному пути. autocomplete — последнее слово ищется как префикс
    def search_address_objects(query, path_type: :adm, limit: 20, offset: 0, autocomplete: false)
      function, text = tsquery(query, autocomplete)
      return [] unless text

      path = path_column(path_type)
      name = "to_tsvector('russian', ao.name || ' ' || ao.type_name)"
      # Совпадения по пути ищутся, только если по названию не набралось limit + offset:
      # условие на named — однократный фильтр, скан путей тогда не выполняется
      instrument(:search_address_objects, query:) do
        select(AddressObject, <<~SQL, text, limit, offset, hierarchy: path_type)
          WITH q AS (SELECT #{function}('russian', $1) AS q),
          named AS (
            SELECT #{ADDRESS_OBJECT_COLUMNS}, 0 AS phase, ts_rank_cd(#{name}, q.q) AS rank
            FROM #{table(:address_objects)} ao, q
            WHERE ao.is_active AND #{name} @@ q.q
            ORDER BY rank DESC, #{LEVEL_ORDER}, ao.name
            LIMIT $2::int + $3::int
          ),
          by_path AS (
            SELECT #{ADDRESS_OBJECT_COLUMNS}, 1 AS phase, ts_rank_cd(ao.#{path}_tsv, q.q) AS rank
            FROM #{table(:address_objects)} ao, q
            WHERE (SELECT count(*) FROM named) < $2::int + $3::int
              AND ao.is_active AND ao.#{path}_tsv @@ q.q AND NOT #{name} @@ q.q
            ORDER BY rank DESC, #{LEVEL_ORDER}, ao.name
            LIMIT $2::int + $3::int
          )
          SELECT * FROM (SELECT * FROM named UNION ALL SELECT * FROM by_path) ao
          ORDER BY phase, rank DESC, #{LEVEL_ORDER}, name
          LIMIT $2 OFFSET $3
        SQL
      end
    end

    # Полнотекстовый поиск домов по полному пути
    def search_houses(query, path_type: :adm, limit: 20, offset: 0, autocomplete: false)
      function, text = tsquery(query, autocomplete)
      return [] unless text

      path = path_column(path_type)
      instrument(:search_houses, query:) do
        select(House, <<~SQL, text, limit, offset, hierarchy: path_type)
          SELECT #{HOUSE_COLUMNS}
          FROM #{table(:houses)} h
          CROSS JOIN #{function}('russian', $1) q
          LEFT JOIN #{table(:house_types)} ht ON ht.id = h.house_type
          WHERE h.is_active AND h.#{path}_tsv @@ q
          ORDER BY ts_rank_cd(h.#{path}_tsv, q) DESC, h.house_num
          LIMIT $2 OFFSET $3
        SQL
      end
    end

    # Каскадный поиск: регионы (без parent_guid) или прямые потомки объекта по иерархии.
    # level — уровень или список уровней
    def find_address_objects(parent_guid: nil, path_type: :adm, level: nil, limit: 50, offset: 0)
      return [] if parent_guid && !parent_guid.to_s.match?(UUID)

      levels = level && "{#{Array(level).map { Integer(_1) }.join(',')}}"
      instrument(:find_address_objects, parent_guid:) do
        if parent_guid.nil?
          select(AddressObject, <<~SQL, levels || "{1}", limit, offset)
            SELECT #{ADDRESS_OBJECT_COLUMNS} FROM #{table(:address_objects)} ao
            WHERE ao.is_active AND ao.level = ANY($1::int[])
            ORDER BY ao.name
            LIMIT $2 OFFSET $3
          SQL
        else
          select(AddressObject, <<~SQL, parent_guid, levels, limit, offset, hierarchy: path_type)
            SELECT #{ADDRESS_OBJECT_COLUMNS}
            FROM #{children(path_type)}
            JOIN #{table(:address_objects)} ao ON ao.object_id = h.object_id AND ao.is_active
            WHERE $2::int[] IS NULL OR ao.level = ANY($2::int[])
            ORDER BY ao.level, ao.name
            LIMIT $3 OFFSET $4
          SQL
        end
      end
    end

    # Действующие дома — прямые потомки объекта (улицы) по иерархии
    def find_houses(parent_guid, path_type: :adm, limit: 100, offset: 0)
      return [] unless parent_guid.to_s.match?(UUID)

      instrument(:find_houses, parent_guid:) do
        select(House, <<~SQL, parent_guid, limit, offset, hierarchy: path_type)
          SELECT #{HOUSE_COLUMNS}
          FROM #{children(path_type, as: 'hier')}
          JOIN #{table(:houses)} h ON h.object_id = hier.object_id AND h.is_active
          LEFT JOIN #{table(:house_types)} ht ON ht.id = h.house_type
          ORDER BY h.house_num
          LIMIT $2 OFFSET $3
        SQL
      end
    end

    def find_address_object_by_guid(guid)
      return unless guid.to_s.match?(UUID)

      instrument(:find_address_object_by_guid, guid:) do
        select(AddressObject, <<~SQL, guid).first
          SELECT #{ADDRESS_OBJECT_COLUMNS} FROM #{table(:address_objects)} ao
          WHERE ao.object_guid = $1 AND ao.is_active
          LIMIT 1
        SQL
      end
    end

    def find_house_by_guid(guid)
      return unless guid.to_s.match?(UUID)

      instrument(:find_house_by_guid, guid:) do
        select(House, <<~SQL, guid).first
          SELECT #{HOUSE_COLUMNS} FROM #{table(:houses)} h
          LEFT JOIN #{table(:house_types)} ht ON ht.id = h.house_type
          WHERE h.object_guid = $1 AND h.is_active
          LIMIT 1
        SQL
      end
    end

    ADDRESS_OBJECT_COLUMNS = "ao.id, ao.object_id, ao.object_guid, ao.name, ao.type_name, ao.level, ao.full_adm_path, ao.full_mun_path"
    HOUSE_COLUMNS          = "h.id, h.object_id, h.object_guid, h.house_num, ht.short_name AS house_type, h.full_adm_path, h.full_mun_path"
    private_constant :ADDRESS_OBJECT_COLUMNS, :HOUSE_COLUMNS

    private

    # hierarchy — иерархия запроса: пустой ответ или ошибка «нет таблицы» проверяются на то, что
    # её не загружали. Удачный запрос лишнего обращения к базе не делает
    def select(result_class, sql, *params, hierarchy: nil)
      rows = Database.with_connection(db_conn) { |conn| conn.exec_params(sql, params).map { result_class.from_row(_1) } }
      require_hierarchy(hierarchy) if hierarchy && rows.empty?
      rows
    rescue PG::UndefinedTable
      require_hierarchy(hierarchy) if hierarchy
      raise
    end

    def require_hierarchy(path_type)
      name   = table(Configuration::HIERARCHY_TABLES.fetch(path_type))
      exists = Database.with_connection(db_conn) { _1.exec_params("SELECT to_regclass($1)", [name]).getvalue(0, 0) }
      raise ConfigurationError, "Иерархия #{path_type} не загружена: в схеме #{schema} нет таблицы #{name}" unless exists
    end

    # Действующие строки иерархии (алиас as) — прямые потомки действующего объекта с GUID $1
    def children(path_type, as: "h")
      hierarchy = table(Configuration::HIERARCHY_TABLES.fetch(check_path_type(path_type)))
      "#{hierarchy} #{as} JOIN #{table(:address_objects)} parent ON parent.object_id = #{as}.parent_obj_id " \
        "AND parent.object_guid = $1 AND parent.is_active AND #{as}.is_active"
    end

    # Функция tsquery и текст запроса; текст nil — пустой запрос
    def tsquery(query, autocomplete)
      if autocomplete
        words = query.to_s.gsub(/[!|&:*()\\'"<>]/, " ").split
        ["to_tsquery", ("#{words.join(' & ')}:*" if words.any?)]
      else
        ["websearch_to_tsquery", query.to_s.strip.then { _1 unless _1.empty? }]
      end
    end

    def path_column(path_type) = "full_#{check_path_type(path_type)}_path"

    def check_path_type(path_type)
      return path_type if Configuration::HIERARCHY_TABLES.key?(path_type)

      raise ArgumentError, "path_type: #{Configuration::HIERARCHY_TABLES.keys.map(&:inspect).join(' или ')}, получено #{path_type.inspect}"
    end

    def instrument(method, **payload)
      Gar.instrument("search.gar", { method:, schema:, **payload }) do |event|
        yield.tap { event[:count] = Array(_1).size }
      end
    end

    def table(name) = Schema.fetch(name).qualified_name(schema)
  end
end
