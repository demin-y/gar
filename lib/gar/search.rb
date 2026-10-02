# frozen_string_literal: true

module Gar
  # Поиск по текущей схеме ГАР (config.database_schema). Результаты — AddressObject и House.
  #
  # Без явного соединения каждый вызов берёт соединение из пула (Gar.with_connection) только
  # на время запроса, поэтому один объект Search можно делить между потоками. Недоступная
  # база или statement_timeout — Gar::UnavailableError. Если загружен ActiveSupport, каждый
  # вызов публикует событие search.gar (метод, запрос, число результатов).
  #
  # path_type — иерархия: :adm (административная) или :mun (муниципальная).
  class Search
    include Loggable

    PATH_TYPES = [:adm, :mun].freeze
    UUID       = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
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
      search_query = tsquery(query, autocomplete)
      return [] unless search_query

      path = path_column(path_type)
      name = "to_tsvector('russian', ao.name || ' ' || ao.type_name)"
      instrument(:search_address_objects, query:) do
        select(AddressObject, <<~SQL, search_query, limit, offset)
          SELECT * FROM (
            SELECT #{ADDRESS_OBJECT_COLUMNS}, 0 AS phase, ts_rank_cd(#{name}, q) AS rank
            FROM #{table(:address_objects)} ao, #{search_query[:function]}('russian', $1) q
            WHERE ao.is_active AND #{name} @@ q
            UNION ALL
            SELECT #{ADDRESS_OBJECT_COLUMNS}, 1, ts_rank_cd(ao.#{path}_tsv, q)
            FROM #{table(:address_objects)} ao, #{search_query[:function]}('russian', $1) q
            WHERE ao.is_active AND ao.#{path}_tsv @@ q AND NOT #{name} @@ q
          ) ao
          ORDER BY phase, rank DESC, #{LEVEL_ORDER}, name
          LIMIT $2 OFFSET $3
        SQL
      end
    end

    # Полнотекстовый поиск домов по полному пути
    def search_houses(query, path_type: :adm, limit: 20, offset: 0, autocomplete: false)
      search_query = tsquery(query, autocomplete)
      return [] unless search_query

      path = path_column(path_type)
      instrument(:search_houses, query:) do
        select(House, <<~SQL, search_query, limit, offset)
          SELECT #{HOUSE_COLUMNS}
          FROM #{table(:houses)} h
          CROSS JOIN #{search_query[:function]}('russian', $1) q
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
          next [] unless parent_guid.to_s.match?(UUID)

          select(AddressObject, <<~SQL, parent_guid, levels, limit, offset)
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
        select(House, <<~SQL, parent_guid, limit, offset)
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

    def select(result_class, sql, *params)
      params = params.map { _1.is_a?(Hash) ? _1[:text] : _1 }
      with_connection { |conn| conn.exec_params(sql, params).map { result_class.from_row(_1) } }
    end

    def with_connection(&)
      return Gar.with_connection(&) unless db_conn

      begin
        yield db_conn
      rescue *Database::UNAVAILABLE_ERRORS => e
        raise UnavailableError, "База ГАР недоступна: #{e.message.strip}"
      end
    end

    # Действующие строки иерархии (алиас as) — прямые потомки действующего объекта с GUID $1
    def children(path_type, as: "h")
      hierarchy = table(Configuration::HIERARCHY_TABLES.fetch(check_path_type(path_type)))
      "#{hierarchy} #{as} JOIN #{table(:address_objects)} parent ON parent.object_id = #{as}.parent_obj_id " \
        "AND parent.object_guid = $1 AND parent.is_active AND #{as}.is_active"
    end

    # Текст запроса и функция tsquery; nil — пустой запрос
    def tsquery(query, autocomplete)
      if autocomplete
        words = query.to_s.gsub(/[!|&:*()\\'"<>]/, " ").split
        { text: "#{words.join(' & ')}:*", function: "to_tsquery" } if words.any?
      else
        { text: query.to_s.strip, function: "websearch_to_tsquery" } unless query.to_s.strip.empty?
      end
    end

    def path_column(path_type) = "full_#{check_path_type(path_type)}_path"

    def check_path_type(path_type)
      PATH_TYPES.include?(path_type) ? path_type : raise(ArgumentError, "path_type: :adm или :mun, получено #{path_type.inspect}")
    end

    def instrument(method, **payload)
      return yield unless defined?(ActiveSupport::Notifications)

      ActiveSupport::Notifications.instrument("search.gar", method:, schema:, **payload) do |event|
        yield.tap { event[:count] = _1.nil? ? 0 : Array(_1).size }
      end
    end

    def table(name) = "#{Schema.quote(schema)}.#{Schema.quote(name)}"
  end
end
