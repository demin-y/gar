# frozen_string_literal: true

require "ox"

module Gar
  # Потоковый разбор XML таблицы ГАР (Ox SAX) в строки COPY text format.
  #
  # Берёт только атрибуты колонок таблицы в порядке Schema::Table#copy_columns; отсутствующий
  # или пустой атрибут — NULL. Значения ФНС уже годятся для COPY как есть (даты YYYY-MM-DD,
  # 0/1 и true/false для boolean), поэтому строки собираются без преобразования типов.
  # Записи, не прошедшие фильтры (атрибут → допустимые значения), отбрасываются.
  #
  #   reader = Gar::XmlReader.new(Gar::Schema.fetch(:houses), filters: { "ISACTUAL" => ["1"] }, region_code: "43")
  #   reader.read(io) { |chunk| conn.put_copy_data(chunk) }
  class XmlReader < Ox::Sax
    CHUNK_SIZE = 1 << 16
    NULL       = "\\N"
    ESCAPE     = /[\\\t\n\r]/
    ESCAPES    = { "\\" => "\\\\", "\t" => "\\t", "\n" => "\\n", "\r" => "\\r" }.freeze

    # Ox читает поток кусками по ~4 КБ, а каждое чтение из zip дорогое: отдаём ему куски
    # из буфера, который пополняется по мегабайту
    class BufferedIO
      def initialize(io, size = 1 << 20)
        @io       = io
        @size     = size
        @chunk    = "".b
        @position = 0
      end

      def readpartial(length, _buffer = nil)
        if @position >= @chunk.bytesize
          @chunk = @io.read(@size)
          raise EOFError if @chunk.nil? || @chunk.empty?

          @position = 0
        end
        part = @chunk.byteslice(@position, length)
        @position += part.bytesize
        part
      end
    end

    # filters — { "ISACTUAL" => ["1"] }: атрибут должен быть колонкой таблицы;
    # region_code — код субъекта для колонки region_code (последняя в строке COPY)
    def initialize(table, filters: {}, region_code: nil)
      super()
      @element  = table.element.to_sym
      @index    = table.columns.each_with_index.to_h { |column, index| [column.attribute.to_sym, index] }
      @values   = Array.new(@index.size)
      @filters  = filters.map { |attribute, allowed| [@index.fetch(attribute.to_sym), allowed.map(&:to_s)] }
      @line_end = table.region_code ? "\t#{region_code || NULL}\n" : "\n"
    end

    # Разбирает поток и отдаёт блоку куски строк COPY; возвращает число принятых записей
    def read(io, &block)
      @block  = block
      @buffer = +""
      @count  = 0
      Ox.sax_parse(self, BufferedIO.new(io))
      flush
      @count
    end

    def start_element(name)
      return unless name == @element

      @inside = true
      @values.fill(nil)
    end

    def attr(name, value)
      return unless @inside

      index = @index[name]
      @values[index] = value if index
    end

    def end_element(name)
      return unless @inside && name == @element

      @inside = false
      return unless @filters.all? { |index, allowed| allowed.include?(@values[index]) }

      @buffer << copy_line
      @count += 1
      flush if @buffer.bytesize >= CHUNK_SIZE
    end

    def error(message, line, column)
      raise ImportError, "Ошибка разбора XML (строка #{line}, позиция #{column}): #{message}"
    end

    private

    def copy_line
      @values.map { |value| value.nil? || value.empty? ? NULL : escape(value) }.join("\t") << @line_end
    end

    def escape(value)
      value.match?(ESCAPE) ? value.gsub(ESCAPE, ESCAPES) : value
    end

    def flush
      return if @buffer.empty?

      @block.call(@buffer)
      @buffer = +""
    end
  end
end
