# frozen_string_literal: true

module Gar
  # Автодополнение одной строки ввода (Т7): «Киров, Ленина 10б» → дома и улицы одним списком
  # Suggestion. Строка делится на текст и номер дома (Gar::HouseNumber) — номер начинается с
  # первого слова-числа после текста, за которым идёт только номер, корпус и строение.
  #
  # - Без номера — адресные объекты по тексту (последнее слово — префикс).
  # - С номером — дома на лучших улицах текста: сначала точный номер (без корпуса и строения,
  #   если их не ввели), затем номера, которые начинаются с введённого; после домов — сами улицы.
  # - Шесть цифр — почтовый индекс (Search#search_address_objects).
  class Autocomplete
    # Сколько улиц текста просматривать на дома
    STREETS = 10

    attr_reader :search

    def initialize(search = Search.new) = @search = search

    def call(query, limit: 10, **scope)
      hierarchy    = search.resolve(scope[:hierarchy])
      text, number = split(Synonyms.words(query))
      Gar.instrument("search.gar", { method: :autocomplete, schema: search.schema, query: }) do |event|
        count       = number ? STREETS : limit
        streets     = text.empty? ? [] : search.search_address_objects(text.join(" "), **scope, limit: count, autocomplete: true)
        houses      = number && streets.any? ? houses(streets, number, hierarchy, limit) : []
        suggestions = [*houses.map { house(_1, hierarchy) }, *streets.map { address_object(_1, hierarchy) }]
        suggestions.first(limit).tap { event[:count] = _1.size }
      end
    end

    private

    # Слова → [текст, HouseNumber или nil]. Число в начале — часть текста («1-я Заречная»)
    def split(words)
      (1...words.size).each do |index|
        next unless words[index].match?(/\A\d/)

        number = HouseNumber.from_words(words[index..])
        return [words[...index], number] if number
      end
      [words, nil]
    end

    # Дома улиц streets с номером number; границы поиска уже применены к улицам
    def houses(streets, number, hierarchy, limit)
      search.query(House, :autocomplete_houses, { query: number.number }, hierarchy:) do |sql|
        ids   = sql.bind_array(streets.map(&:gar_object_id), :bigint)
        exact = sql.bind(number.number)
        parts =
          HouseNumber::TYPES.filter_map do |part, type|
            value = number.public_send(part) or next
            "AND ((lower(a1.name) = '#{type}' AND h.add_num1 = #{sql.bind(value)}) OR (lower(a2.name) = '#{type}' AND h.add_num2 = #{sql.bind(value)}))"
          end
        <<~SQL
          SELECT #{Search::HOUSE_COLUMNS}
          FROM #{sql.hierarchy_table} hier
          JOIN #{search.table(:houses)} h ON h.object_id = hier.object_id AND h.is_active
          LEFT JOIN #{search.table(:house_types)} ht ON ht.id = h.house_type
          LEFT JOIN #{search.table(:add_house_types)} a1 ON a1.id = h.add_type1
          LEFT JOIN #{search.table(:add_house_types)} a2 ON a2.id = h.add_type2
          WHERE hier.is_active AND hier.parent_obj_id = ANY(#{ids})
            AND starts_with(h.house_num_norm, #{exact}) #{parts.join(' ')}
          ORDER BY h.house_num_norm = #{exact} DESC, (h.add_num1 IS NULL AND h.add_num2 IS NULL) DESC,
                   array_position(#{ids}, hier.parent_obj_id), length(h.house_num_norm), h.house_num_norm, h.add_num1, h.add_num2
          LIMIT #{sql.bind(limit)}
        SQL
      end
    end

    # Дом: имя — номер с типами из конца полного пути («д. 10 к. 2»); путь ещё не построен —
    # тип и основной номер
    def house(house, hierarchy)
      address = house.public_send(:"full_#{hierarchy}_path")
      name    = address ? address.split(", ").last : [house.house_type, house.house_num].compact.join(" ")
      Suggestion.new(kind: :house, object_guid: house.object_guid, gar_object_id: house.gar_object_id, level: AddressBuilder::HOUSE_LEVEL,
                     region_code: house.region_code, name:, address:)
    end

    def address_object(object, hierarchy)
      Suggestion.new(kind: :address_object, object_guid: object.object_guid, gar_object_id: object.gar_object_id, level: object.level,
                     region_code: object.region_code, name: "#{object.name} #{object.type_name}",
                     address: object.public_send(:"full_#{hierarchy}_path"))
    end
  end
end
