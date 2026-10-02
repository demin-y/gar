# frozen_string_literal: true

module Gar
  HouseNumber = Data.define(:number, :building, :structure)

  # Номер дома из ввода: основной номер с литерой или дробью («10», «10а», «10/2») и
  # необязательные корпус и строение — «10 к2», «10 корп. 2 стр 1», «12а к 2». Слова частей
  # дома — из групп «корпус» и «строение» встроенных синонимов. number — в том же виде, что
  # houses.house_num_norm: без пробелов, в нижнем регистре, ё → е.
  class HouseNumber
    # Части дома — полные имена дополнительных типов ГАР (add_house_types)
    TYPES = { building: "корпус", structure: "строение" }.freeze
    PARTS = TYPES.transform_values { |word| Synonyms.builtin.find { _1.include?(word) } }.freeze

    class << self
      def parse(text) = from_words(Synonyms.words(text))

      # Слова (Synonyms.words) → HouseNumber или nil, если это не номер дома
      def from_words(words)
        tokens = words.join(" ").scan(%r{\d+|[[:alpha:]]+|/})
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
