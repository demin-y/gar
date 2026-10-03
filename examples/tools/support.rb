# frozen_string_literal: true

require "bundler/setup"
require "gar"

module GarTools
  # Отчёт проверок схем ГАР: по каждой проверке — число найденных строк (расхождений) и до 5
  # примеров; finish печатает итог и завершает скрипт с кодом 1, если расхождения есть
  class Report
    def initialize(conn, indent: "")
      @conn   = conn
      @indent = indent
      @failed = false
    end

    # SQL проверки отдаёт строки-расхождения
    def check(title, sql)
      rows = @conn.exec(sql).values
      @failed ||= rows.any?
      puts "#{@indent}#{title.ljust(62 - @indent.size)} #{rows.size}"
      rows.first(5).each { puts "#{@indent}    #{_1.map { |value| value.to_s[0, 120] }.join(' | ')}" }
    end

    def finish(passed)
      puts @failed ? "Есть расхождения" : passed
      exit(@failed ? 1 : 0)
    end
  end
end
