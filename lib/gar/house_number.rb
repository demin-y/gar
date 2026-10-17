# frozen_string_literal: true

module Gar
  HouseNumber = Data.define(:number, :building, :structure)

  # Номер дома из ввода: основной номер с литерой или дробью («10», «10а», «10 лит. А», «10/2»)
  # и необязательные корпус и строение — «10 к2», «10 корп. 2 стр 1», «12а к 2». Помещение после
  # номера («10 кв. 5», «12 к. 2 оф. 3») номер заканчивает и отбрасывается. Слова частей дома,
  # литеры и помещений — из групп встроенных синонимов. number — в том же виде, что
  # houses.house_num_norm: без пробелов, в нижнем регистре, ё → е; латинские буквы, похожие на
  # русские («10a», «10 k2»), заменяются русскими.
  class HouseNumber
    # Группа встроенных синонимов, в которой есть слово word
    def self.group(word) = Synonyms.builtin.find { _1.include?(word) } || raise(KeyError, "Нет группы синонимов «#{word}»")

    # Части дома — полные имена дополнительных типов ГАР (add_house_types)
    TYPES = { building: "корпус", structure: "строение" }.freeze
    # Слова частей только внутри номера («77с2», «77 к1 с2»): в тексте адреса «с» — это «село»
    HOUSE_ONLY = { structure: ["с"] }.freeze
    PARTS      = TYPES.to_h { |part, type| [part, group(type) + HOUSE_ONLY.fetch(part, [])] }.freeze
    # Дополнительный тип ГАР, номер которого — часть основного номера («18 литера Б» — «18б»)
    LETTER       = "литера"
    LETTER_WORDS = group(LETTER).freeze
    # Тип дома перед номером в строке адреса («д. 10», «влд 5») и помещения после него
    HOUSE_WORDS   = ["дом", "владение", "домовладение", "здание", "сооружение"].flat_map { group(_1) }.freeze
    PREMISE_WORDS = ["квартира", "офис", "помещение", "комната"].flat_map { group(_1) }.freeze
    # Тип дома ГАР «Дом» (полное имя): при одинаковом номере на улице — раньше строения,
    # сооружения и здания («д. 1» и «стр. 1»)
    DWELLING = "дом"
    # Латинские буквы, которые набирают вместо похожих русских (в нижнем регистре: «B» → «в»)
    LATIN    = "abcehkmoptxy"
    CYRILLIC = "авсенкмортху"

    class << self
      def parse(text) = from_words(Synonyms.words(text))

      # Значение части номера для сравнения: «2 А» → «2а», «2a» → «2а»
      def normalize(value) = Synonyms.words(value).join.tr(LATIN, CYRILLIC)

      # Номер для сравнения: [номер, части { building:, structure: }]; не номер дома — сам текст
      # в виде для сравнения и без частей
      def comparable(text)
        parsed = parse(text)
        [parsed&.number || normalize(text), parsed&.parts || {}]
      end

      # Номер дома ГАР для сравнения: house_num и дополнительные номера [[полное имя типа,
      # номер], …] → [номер, части]: литера дописывается к номеру, остальное — parts
      def of_house(house_num, additions)
        number, parts = comparable(house_num.to_s)
        [number + normalize(letters(additions)), parts.merge(additional_parts(additions).transform_values { normalize(_1) })]
      end

      # Части номера дома ГАР — дополнительные номера [[полное имя типа, номер], …] кроме литеры:
      # корпус и строение — под ключами TYPES (:building, :structure), прочие — под именем своего
      # типа (:сооружение). Тип самого дома частью не бывает: «стр. 9» — номер 9 с типом
      # «строение», а не строение 9 (Gar.address и Gar.match_house — одинаково)
      def additional_parts(additions)
        additions.each_with_object({}) do |(type, value), parts|
          next if value.nil? || letter_type?(type)

          type = type.to_s.downcase
          parts[TYPES.key(type) || type.to_sym] = value
        end
      end

      # Литера из дополнительных номеров [[полное имя типа, номер], …] как в ГАР («18» и литера
      # «Б» — «Б»); для сравнения — через normalize
      def letters(additions) = additions.filter_map { |type, value| value.strip if value && letter_type?(type) }.join

      def letter_type?(type) = type.to_s.downcase == LETTER

      # Слова (Synonyms.words) → HouseNumber или nil, если это не номер дома
      def from_words(words)
        tokens = words.join(" ").tr(LATIN, CYRILLIC).scan(%r{\d+|[[:alpha:]]+|/})
        return unless digit?(tokens.first)

        number = with_letter(+tokens.shift, tokens)
        number << with_letter(tokens.shift(2).join, tokens) if tokens[0] == "/" && digit?(tokens[1])
        parts = parts(tokens) or return
        new(number:, **parts)
      end

      private

      # Корпус и строение: слово части и номер, каждая часть один раз; помещение заканчивает
      # номер; лишнее — nil
      def parts(tokens)
        parts = {}
        until tokens.empty? || PREMISE_WORDS.include?(tokens.first)
          name  = part(tokens.shift)
          value = tokens.shift
          return unless name && digit?(value) && !parts.key?(name)

          parts[name] = with_letter(value, tokens)
        end
        parts
      end

      # Номер и литера за ним («10 а», «10 лит. а» → «10а»); слово части дома с номером — не литера
      def with_letter(value, tokens)
        tokens.shift if LETTER_WORDS.include?(tokens[0]) && letter?(tokens[1])
        letter = letter?(tokens[0]) && !(part(tokens[0]) && digit?(tokens[1]))
        letter ? value + tokens.shift : value
      end

      def letter?(token) = token&.match?(/\A[[:alpha:]]\z/)

      def part(word) = PARTS.find { |_, words| words.include?(word) }&.first

      def digit?(token) = token&.match?(/\A\d/)
    end

    def initialize(number:, building: nil, structure: nil) = super

    # Части номера для сравнения с Gar::HouseMatcher::Candidate#parts: { building:, structure: } без пустых
    def parts = { building:, structure: }.compact
  end
end
