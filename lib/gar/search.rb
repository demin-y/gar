# frozen_string_literal: true

module Gar
  # Поиск по текущей схеме ГАР (config.database_schema). Результаты — AddressObject и House.
  #
  # Без явного соединения каждый вызов берёт соединение из пула (Gar.with_connection) только
  # на время запроса, поэтому один объект Search можно делить между потоками. Недоступная
  # база или statement_timeout — Gar::UnavailableError. Если загружен ActiveSupport, каждый
  # вызов публикует событие search.gar (метод, запрос, число результатов).
  #
  # Общие параметры методов:
  # - hierarchy: — :adm (административная) или :mun (муниципальная), по умолчанию
  #   config.default_hierarchy. Если иерархии нет в схеме (импорт с config.hierarchies без
  #   неё), поиск по ней бросает ConfigurationError, а не отвечает пустым списком;
  # - region_codes: — только объекты этих субъектов (%w[43 11]);
  # - within: — GUID адресного объекта (субъект, район, город): только объекты в его поддереве
  #   по иерархии запроса, включая его самого.
  #
  # Текстовый запрос нормализуется (регистр, ё, точки), каждое слово ищется вместе с
  # синонимами (Gar::Synonyms): «просп. Октябрьский» находит «Октябрьский пр-кт».
  class Search
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    POSTAL_CODE = /\A\d{6}\z/
    POSTAL_CODE_PARAM = 5
    # Порядок адресных объектов при равной текстовой близости: административные центры, затем
    # объекты с большим числом домов («Киров» — город раньше деревень «Кировский»), затем
    # регионы, районы, города, населённые пункты и улицы
    RANK_ORDER = "ao.is_capital IS TRUE DESC, ao.house_count DESC NULLS LAST, array_position(ARRAY[1, 2, 5, 6, 7, 8], ao.level), ao.name"
    ADDRESS_OBJECT_COLUMNS = "ao.id, ao.object_id, ao.object_guid, ao.name, ao.type_name, ao.level, ao.region_code, ao.full_adm_path, ao.full_mun_path"
    HOUSE_COLUMNS          = "h.id, h.object_id, h.object_guid, h.house_num, ht.short_name AS house_type, h.region_code, " \
                             "h.full_adm_path, h.full_mun_path"

    attr_reader :db_conn, :schema

    # db_conn — своё соединение вместо пула (его закрывает вызывающий)
    def initialize(db_conn = nil, schema: Gar.configuration.database_schema)
      @db_conn = db_conn
      @schema  = schema
    end

    # Полнотекстовый поиск адресных объектов: сначала совпадения по названию (точные — выше),
    # затем — только по полному пути. autocomplete — последнее слово ищется как префикс.
    # Шесть цифр — почтовый индекс: объекты с этим индексом и улицы его домов
    def search_address_objects(query, limit: 20, offset: 0, autocomplete: false, **scope)
      text = query.to_s.strip
      return find_by_postal_code(text, limit:, offset:, **scope) if text.match?(POSTAL_CODE)

      words = Synonyms.words(text)
      return [] if words.empty?

      synonyms = self.synonyms
      query(AddressObject, :search_address_objects, { query: }, **scope) do |sql|
        typed = sql.bind(synonyms.tsquery(words, prefix: autocomplete))
        exact = sql.bind(synonyms.tsquery(words))
        bound = sql.bounds("ao")
        first = sql.bind(limit)
        skip  = sql.bind(offset)
        count = "#{first}::int + #{skip}::int"
        path  = "ao.full_#{sql.hierarchy}_path_tsv"
        # Совпадения по пути ищутся, только если по названию не набралось limit + offset:
        # условие на named — однократный фильтр, скан путей тогда не выполняется
        <<~SQL
          WITH q AS (SELECT to_tsquery('russian', #{typed}) AS typed, to_tsquery('russian', #{exact}) AS exact),
          named AS (
            SELECT #{ADDRESS_OBJECT_COLUMNS}, #{RANK_COLUMNS}, 0 AS phase, ao.name_tsv @@ q.exact AS exact, 0 AS rank
            FROM #{table(:address_objects)} ao, q
            WHERE ao.is_active AND ao.name_tsv @@ q.typed #{bound}
            ORDER BY exact DESC, #{RANK_ORDER}
            LIMIT #{count}
          ),
          by_path AS (
            SELECT #{ADDRESS_OBJECT_COLUMNS}, #{RANK_COLUMNS}, 1 AS phase, #{path} @@ q.exact AS exact, ts_rank_cd(#{path}, q.typed) AS rank
            FROM #{table(:address_objects)} ao, q
            WHERE (SELECT count(*) FROM named) < #{count}
              AND ao.is_active AND #{path} @@ q.typed AND NOT ao.name_tsv @@ q.typed #{bound}
            ORDER BY exact DESC, rank DESC, #{RANK_ORDER}
            LIMIT #{count}
          )
          SELECT * FROM (SELECT * FROM named UNION ALL SELECT * FROM by_path) ao
          ORDER BY phase, exact DESC, rank DESC, #{RANK_ORDER}
          LIMIT #{first} OFFSET #{skip}
        SQL
      end
    end

    # Полнотекстовый поиск домов по полному пути
    def search_houses(query, limit: 20, offset: 0, autocomplete: false, **scope)
      words = Synonyms.words(query)
      return [] if words.empty?

      synonyms = self.synonyms
      query(House, :search_houses, { query: }, **scope) do |sql|
        path = "h.full_#{sql.hierarchy}_path_tsv"
        <<~SQL
          SELECT #{HOUSE_COLUMNS}
          FROM #{table(:houses)} h
          CROSS JOIN to_tsquery('russian', #{sql.bind(synonyms.tsquery(words, prefix: autocomplete))}) q
          LEFT JOIN #{table(:house_types)} ht ON ht.id = h.house_type
          WHERE h.is_active AND #{path} @@ q #{sql.bounds('h')}
          ORDER BY ts_rank_cd(#{path}, q) DESC, h.house_num
          #{sql.page(limit, offset)}
        SQL
      end
    end

    # Каскадный поиск: регионы (без parent_guid) или прямые потомки объекта по иерархии.
    # level — уровень или список уровней
    def find_address_objects(parent_guid: nil, level: nil, limit: 50, offset: 0, **scope)
      return [] if parent_guid && !parent_guid.to_s.match?(UUID)

      levels = Array(level || (1 unless parent_guid)).map { Integer(_1) }
      query(AddressObject, :find_address_objects, { parent_guid: }, **scope) do |sql|
        source = "#{table(:address_objects)} ao"
        source = "#{sql.children(parent_guid)} JOIN #{source} ON ao.object_id = hier.object_id" if parent_guid
        <<~SQL
          SELECT #{ADDRESS_OBJECT_COLUMNS}
          FROM #{source}
          WHERE ao.is_active #{"AND ao.level = ANY(#{sql.bind_array(levels, :int)})" if levels.any?} #{sql.bounds('ao')}
          ORDER BY #{'ao.level, ' if parent_guid}ao.name
          #{sql.page(limit, offset)}
        SQL
      end
    end

    # Действующие дома — прямые потомки объекта (улицы) по иерархии
    def find_houses(parent_guid, limit: 100, offset: 0, **scope)
      return [] unless parent_guid.to_s.match?(UUID)

      query(House, :find_houses, { parent_guid: }, **scope) do |sql|
        <<~SQL
          SELECT #{HOUSE_COLUMNS}
          FROM #{sql.children(parent_guid)}
          JOIN #{table(:houses)} h ON h.object_id = hier.object_id AND h.is_active
          LEFT JOIN #{table(:house_types)} ht ON ht.id = h.house_type
          WHERE true #{sql.bounds('h')}
          ORDER BY h.house_num_norm
          #{sql.page(limit, offset)}
        SQL
      end
    end

    def find_address_object_by_guid(guid, **scope)
      return unless guid.to_s.match?(UUID)

      query(AddressObject, :find_address_object_by_guid, { guid: }, **scope) do |sql|
        <<~SQL
          SELECT #{ADDRESS_OBJECT_COLUMNS} FROM #{table(:address_objects)} ao
          WHERE ao.object_guid = #{sql.bind(guid)} AND ao.is_active #{sql.bounds('ao')}
          LIMIT 1
        SQL
      end.first
    end

    def find_house_by_guid(guid, **scope)
      return unless guid.to_s.match?(UUID)

      query(House, :find_house_by_guid, { guid: }, **scope) do |sql|
        <<~SQL
          SELECT #{HOUSE_COLUMNS} FROM #{table(:houses)} h
          LEFT JOIN #{table(:house_types)} ht ON ht.id = h.house_type
          WHERE h.object_guid = #{sql.bind(guid)} AND h.is_active #{sql.bounds('h')}
          LIMIT 1
        SQL
      end.first
    end

    # Синонимы схемы (Gar::Synonyms) с текущими настройками
    def synonyms = Synonyms.for(schema, db_conn)

    def table(name) = Schema.fetch(name).qualified_name(schema)

    # Иерархия запроса: переданная или config.default_hierarchy; неизвестная — ArgumentError
    def resolve(hierarchy)
      Configuration.hierarchy(hierarchy || Gar.configuration.default_hierarchy)
    rescue ConfigurationError => e
      raise ArgumentError, e.message
    end

    # Запрос с результатами result_class и событием search.gar (для Autocomplete). Блок
    # получает Sql с границами (hierarchy:, region_codes:, within:) и соединение, возвращает
    # SQL. Если запрос обращался к иерархии, пустой ответ или «нет таблицы» проверяются на то,
    # что её не загружали; удачный запрос лишнего обращения к базе не делает
    def query(result_class, method, payload, hierarchy: nil, region_codes: nil, within: nil)
      sql = Sql.new(self, resolve(hierarchy), region_codes, within)
      Gar.instrument("search.gar", { method:, schema:, **payload }) do |event|
        Database.with_connection(db_conn) do |conn|
          text = yield sql, conn
          rows = text ? conn.exec_params(text, sql.params).map { result_class.from_row(_1) } : []
          require_hierarchy(conn, sql.hierarchy) if rows.empty? && sql.hierarchy_used?
          event[:count] = rows.size
          rows
        rescue PG::UndefinedTable
          require_hierarchy(conn, sql.hierarchy) if sql.hierarchy_used?
          raise
        end
      end
    end

    # ConfigurationError, если иерархии нет в схеме
    def require_hierarchy(conn, hierarchy)
      name = hierarchy_table(hierarchy)
      return if Database.relation_exists?(conn, name)

      raise ConfigurationError, "Иерархия #{hierarchy} не загружена: в схеме #{schema} нет таблицы #{name}"
    end

    def hierarchy_table(hierarchy) = table(Configuration::HIERARCHY_TABLES.fetch(hierarchy))

    # SQL одного запроса: параметры ($n), страница и границы поиска
    class Sql
      attr_reader :params

      def initialize(search, hierarchy, region_codes, within)
        raise ArgumentError, "within: — GUID адресного объекта, получено #{within.inspect}" if within && !within.to_s.match?(UUID)

        @search       = search
        @hierarchy    = hierarchy
        @region_codes = region_codes && Configuration.region_codes(region_codes)
        @within       = within
        @params       = []
      end

      # Кладёт значение в параметры и возвращает «$n»
      def bind(value)
        @params << value
        "$#{@params.size}"
      end

      def bind_array(values, type) = "#{bind(Database.array(values))}::#{type}[]"

      def page(limit, offset) = "LIMIT #{bind(limit)} OFFSET #{bind(offset)}"

      # Иерархия запроса; обращение к ней отмечает, что запрос от неё зависит
      def hierarchy
        @hierarchy_used = true
        @hierarchy
      end

      def hierarchy_used? = @hierarchy_used || false

      def hierarchy_table = @search.hierarchy_table(hierarchy)

      # Условия границ для алиаса таблицы с region_code и путями
      def bounds(as)
        conditions = []
        conditions << "#{as}.region_code = ANY(#{bind_array(@region_codes, :text)})" if @region_codes&.any?
        if @within
          conditions << "#{as}.#{hierarchy}_path_ids @> ARRAY[(SELECT object_id FROM #{@search.table(:address_objects)} " \
                        "WHERE object_guid = #{bind(@within)} AND is_active LIMIT 1)]"
        end
        conditions.map { "AND #{_1}" }.join(" ")
      end

      # Действующие строки иерархии (алиас hier) — прямые потомки действующего объекта parent_guid
      def children(parent_guid)
        "#{hierarchy_table} hier JOIN #{@search.table(:address_objects)} parent ON parent.object_id = hier.parent_obj_id " \
          "AND parent.object_guid = #{bind(parent_guid)} AND parent.is_active AND hier.is_active"
      end
    end

    RANK_COLUMNS = "ao.is_capital, ao.house_count"
    private_constant :RANK_COLUMNS

    private

    # Объекты с почтовым индексом (параметр 5) и родители домов с ним — улицы индекса.
    # Без таблиц параметров — пустой ответ
    def find_by_postal_code(code, limit:, offset:, **scope)
      query(AddressObject, :search_address_objects, { query: code }, **scope) do |sql, conn|
        value   = sql.bind(code)
        params  = Database.existing_relations(conn, [table(:addr_obj_params), table(:house_params)])
        sources = []
        if params.include?(table(:addr_obj_params))
          sources << "SELECT object_id FROM #{table(:addr_obj_params)} WHERE type_id = #{POSTAL_CODE_PARAM} AND value = #{value}"
        end
        if params.include?(table(:house_params))
          sources << "SELECT hier.parent_obj_id FROM #{table(:house_params)} p JOIN #{sql.hierarchy_table} hier " \
                     "ON hier.object_id = p.object_id AND hier.is_active WHERE p.type_id = #{POSTAL_CODE_PARAM} AND p.value = #{value}"
        end
        next if sources.empty?

        <<~SQL
          SELECT #{ADDRESS_OBJECT_COLUMNS} FROM #{table(:address_objects)} ao
          WHERE ao.is_active AND ao.object_id IN (#{sources.join(' UNION ')}) #{sql.bounds('ao')}
          ORDER BY #{RANK_ORDER}
          #{sql.page(limit, offset)}
        SQL
      end
    end
  end
end
