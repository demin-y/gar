# frozen_string_literal: true

module Gar
  class NullLogger
    def debug(*); end

    def info(*); end

    def warn(*); end

    def error(*); end

    def fatal(*); end

    def level
      Logger::UNKNOWN
    end

    def level=(_); end
  end
end
