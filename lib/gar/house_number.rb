# frozen_string_literal: true

module Gar
  HouseNumber = Data.define(:number, :building, :structure)

  # Номер дома из ввода: основной номер с литерой или дробью («10», «10а», «10/2») и
  # необязательные корпус и строение — «10 к2», «10 корп. 2 стр 1», «12а к 2». Слова частей
  # дома — из групп «корпус» и «строение» встроенных синонимов. number — в том же виде, что
  # houses.house_num_norm: без пробелов, в нижнем регистре, ё → е; латинские буквы, похожие на
  # русские («10a», «10 k2»), заменяются русскими.
  class HouseNumber
    # Части дома — полные имена дополнительных типов ГАР (add_house_types)
    TYPES = { building: "корпус", structure: "строение" }.freeze
    PARTS = TYPES.transform_values { |word| Synonyms.builtin.find { _1.include?(word) } }.freeze
    # Дополнительный тип ГАР, номер которого — часть основного номера («18 литера Б» — «18б»)
    LETTER = "литера"
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
        [parsed&.number || normalize(text), { building: parsed&.building, structure: parsed&.structure }.compact]
      end

      # Номер дома ГАР для сравнения: house_num и дополнительные номера [[полное имя типа,
      # номер], …] → [номер, части]. Корпус и строение — по TYPES, литера дописывается к номеру,
      # прочие дополнительные номера — части под именем своего типа
      def of_house(house_num, additions)
        number, parts = comparable(house_num.to_s)
        additions.each do |type, value|
          next unless value

          type = type.to_s.downcase
          if type == LETTER
            number += normalize(value)
          else
            parts[TYPES.key(type) || type.to_sym] = normalize(value)
          end
        end
        [number, parts]
      end

      # Слова (Synonyms.words) → HouseNumber или nil, если это не номер дома
      def from_words(words)
        tokens = words.join(" ").tr(LATIN, CYRILLIC).scan(%r{\d+|[[:alpha:]]+|/})
        return unless digit?(tokens.first)

        number = with_letter(+tokens.shift, tokens)
        number << tokens.shift(2).join if tokens[0] == "/" && digit?(tokens[1])
        parts = parts(tokens) or return
        new(number:, **parts)
      end

      private

      # Корпус и строение: слово части и номер, каждая часть один раз; лишнее — nil
      def parts(tokens)
        parts = {}
        until tokens.empty?
          name  = part(tokens.shift)
          value = tokens.shift
          return unless name && digit?(value) && !parts.key?(name)

          parts[name] = with_letter(value, tokens)
        end
        parts
      end

      # Номер и литера за ним («10 а» → «10а»); слово части дома с номером — не литера
      def with_letter(value, tokens)
        letter = tokens.first&.match?(/\A[[:alpha:]]\z/) && !(part(tokens[0]) && digit?(tokens[1]))
        letter ? value + tokens.shift : value
      end

      def part(word) = PARTS.find { |_, words| words.include?(word) }&.first

      def digit?(token) = token&.match?(/\A\d/)
    end

    def initialize(number:, building: nil, structure: nil) = super
  end
end
