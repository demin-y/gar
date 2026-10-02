# frozen_string_literal: true

require "pg"
require "logger"
require_relative "gar/version"
require_relative "gar/errors"

module Gar
  autoload :Archive,         "gar/archive"
  autoload :Configuration,   "gar/configuration"
  autoload :Loggable,        "gar/loggable"
  autoload :Database,        "gar/database"
  autoload :Downloader,      "gar/downloader"
  autoload :Importer,        "gar/importer"
  autoload :PathBuilder,     "gar/path_builder"
  autoload :Schema,          "gar/schema"
  autoload :Search,          "gar/search"
  autoload :Utils,           "gar/utils"
  autoload :XmlReader,       "gar/xml_reader"

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    # Возвращает настройки к значениям по умолчанию (тесты, перезагрузка кода в Rails)
    def reset_configuration!
      @configuration = nil
    end

    def logger
      configuration.logger
    end

    def logger=(value)
      configuration.logger = value
    end
  end
end
