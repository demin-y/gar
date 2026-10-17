# frozen_string_literal: true

module Gar
  module Utils
    SIZE_UNITS = ["Б", "КБ", "МБ", "ГБ", "ТБ"].freeze

    # Размер для логов: 1536 → «1.5 КБ»
    def self.format_size(bytes)
      bytes = bytes.to_i
      return "#{bytes} Б" if bytes < 1024

      exp = [(Math.log(bytes) / Math.log(1024)).to_i, SIZE_UNITS.size - 1].min
      "#{(bytes / (1024.0**exp)).round(1)} #{SIZE_UNITS[exp]}"
    end
  end
end
