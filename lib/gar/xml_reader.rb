# frozen_string_literal: true

require "ox"

module Gar
  # Потоковый разбор XML таблицы ГАР (Ox SAX) в строки COPY text format.
  #
  # Берёт только атрибуты колонок таблицы в порядке Schema::Table#copy_columns; отсутствующий
  # или пустой атрибут — NULL. Значения ФНС уже годятся для COPY как есть (даты YYYY-MM-DD,
  # 0/1 и true/false для boolean), поэтому строки собираются без преобразования типов.
  # Записи, не прошедшие фильтры, отбрасываются. Фильтр — атрибут и образец, с которым
  # значение сравнивается через ===: строка, Set, Range, Proc.
  #
  #   reader = Gar::XmlReader.new(Gar::Schema.fetch(:houses), filters: { "ISACTUAL" => "1" }, region_code: "43")
  #   reader.read(io) { |chunk| conn.put_copy_data(chunk) }
  class XmlReader < Ox::Sax
    CHUNK_SIZE = 1 << 16
    NULL       = "\\N"
    ESCAPE     = /[\\\t\n\r]/
    ESCAPES    = { "\\" => "\\\\", "\t" => "\\t", "\n" => "\\n", "\r" => "\\r" }.freeze

    # filters — { "ISACTUAL" => "1", "TYPEID" => Set["5", "7"] }: атрибут должен быть колонкой
    # таблицы; region_code — код субъекта для колонки region_code (последняя в строке COPY)
    def initialize(table, filters: {}, region_code: nil)
      super()
      @element  = table.element.to_sym
      @index    = table.columns.each_with_index.to_h { |column, index| [column.attribute.to_sym, index] }
      @values   = Array.new(@index.size)
      @text     = table.columns.map { _1.type == :text } # спецсимволы COPY возможны только в тексте
      @filters  = filters.map { |attribute, pattern| [@index.fetch(attribute.to_sym), pattern] }
      @line_end = table.region_code ? "\t#{region_code || NULL}\n" : "\n"
    end

    # Разбирает поток (IO с readpartial или read) и отдаёт блоку куски строк COPY около
    # CHUNK_SIZE байт; возвращает число принятых записей. Кусок — один и тот же буфер: после
    # блока он очищается (память освобождается сразу, а не копится мусором до сборки), поэтому
    # блок не должен его хранить — put_copy_data копирует данные.
    def read(io, &block)
      @block  = block
      @buffer = +""
      @count  = 0
      Ox.sax_parse(self, io)
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

      index = @index[name] or return
      @values[index] = @text[index] ? escape(value) : value
    end

    def end_element(name)
      return unless @inside && name == @element

      @inside = false
      return unless @filters.all? { |index, pattern| pattern === @values[index] } # rubocop:disable Style/CaseEquality

      @buffer << copy_line
      @count += 1
      flush if @buffer.bytesize >= CHUNK_SIZE
    end

    def error(message, line, column)
      raise ImportError, "Ошибка разбора XML (строка #{line}, позиция #{column}): #{message}"
    end

    private

    def copy_line
      @values.map { |value| value.nil? || value.empty? ? NULL : value }.join("\t") << @line_end
    end

    def escape(value)
      value.match?(ESCAPE) ? value.gsub(ESCAPE, ESCAPES) : value
    end

    def flush
      return if @buffer.empty?

      @block.call(@buffer)
      @buffer.clear
    end
  end
end
