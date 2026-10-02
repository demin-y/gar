# frozen_string_literal: true

module Gar
  # Сопоставление дома из старой записи адреса (Т11, Gar.match_house): улица по GUID и номер
  # текстом — «10», «10а», «10/2», «д. 12 корп. 2» или по частям (letter:, building:, structure:).
  #
  # Номер записи и номера домов улицы приводятся к одному виду (Gar::HouseNumber: регистр,
  # пробелы, латинские буквы вместо русских; литера из дополнительного типа «литера» — часть
  # номера; корпус и строение из номера — «12к2» — то же, что дополнительные номера):
  # - :exact — совпали номер, корпус и строение;
  # - :fuzzy — с тем же номером ровно один дом, у которого есть всё записанное и что-то сверх
  #   него (в старой записи «12», в ГАР — «12 к. 2»);
  # - :none — иначе, в том числе если таких домов несколько: случайный дом не выбирается.
  # alternatives — другие действующие дома улицы с тем же числом в номере.
  class HouseMatcher
    ALTERNATIVES = 10

    # Дом улицы: результат поиска и номер для сравнения (parts — корпус, строение и прочие
    # дополнительные номера)
    Candidate =
      Data.define(:house, :number, :parts) do
        def self.from_row(row)
          number, parts = HouseNumber.of_house(row["house_num"], [row.values_at("add_name1", "add_num1"), row.values_at("add_name2", "add_num2")])
          new(house: House.from_row(row), number:, parts:)
        end
      end

    attr_reader :search

    def initialize(search = Search.new) = @search = search

    def call(street_guid:, number:, letter: nil, building: nil, structure: nil, hierarchy: nil)
      wanted = wanted(number, letter, building, structure)
      return result(:none, []) unless wanted && street_guid.to_s.match?(Search::UUID)

      related = candidates(street_guid, wanted, hierarchy)
      same    = related.select { _1.number == wanted.number }
      exact   = same.select { _1.parts == wanted.parts }
      wider   = same.select { wanted.parts < _1.parts }
      return result(:exact, related, exact.first) if exact.any?
      return result(:fuzzy, related, wider.first) if wider.one?

      result(:none, related)
    end

    private

    # Запись → Candidate без дома: номер начинается с первого слова-числа («д. 10» — «10»);
    # явные корпус и строение важнее записанных в номере. nil — номера нет
    def wanted(number, letter, building, structure)
      words = Synonyms.words("#{number}#{letter}").drop_while { !_1.match?(/\A\d/) }
      return if words.empty?

      number, parts = HouseNumber.comparable(words.join(" "))
      parts = parts.merge({ building:, structure: }.compact.transform_values { HouseNumber.normalize(_1.to_s) })
      Candidate.new(house: nil, number:, parts: parts.reject { |_, value| value.empty? })
    end

    # Действующие дома улицы с тем же числом в начале номера («10», «10а», «10/2» для «10»)
    def candidates(street_guid, wanted, hierarchy)
      search.query(Candidate, :match_house, { street_guid: }, hierarchy:) do |sql|
        <<~SQL
          SELECT #{Search::HOUSE_COLUMNS}, h.add_num1, a1.name AS add_name1, h.add_num2, a2.name AS add_name2
          FROM #{sql.children(street_guid)}
          JOIN #{search.table(:houses)} h ON h.object_id = hier.object_id AND h.is_active
          #{search.house_type_joins}
          WHERE substring(h.house_num_norm from '^[0-9]+') = #{sql.bind(wanted.number[/\A\d+/])}
          ORDER BY length(h.house_num_norm), h.house_num_norm, h.add_num1 NULLS FIRST, h.add_num2 NULLS FIRST, h.id
        SQL
      end
    end

    # found — выбранный дом (Candidate) или nil; альтернативы — остальные related
    def result(status, related, found = nil)
      HouseMatch.new(status:, house: found&.house, alternatives: (related - [found]).first(ALTERNATIVES).map(&:house))
    end
  end
end
