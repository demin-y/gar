# frozen_string_literal: true

require "pg"
require "httparty"
require "logger"
require_relative "gar/version"

module Gar
  class Error < StandardError; end
  class DownloadError < Error; end

  autoload :Configuration,   "gar/configuration"
  autoload :Loggable,        "gar/loggable"
  autoload :NullLogger,      "gar/null_logger"
  autoload :Database,        "gar/database"
  autoload :Downloader,      "gar/downloader"
  autoload :Entities,        "gar/entities/entities"
  autoload :FullPathBuilder, "gar/full_path_builder"
  autoload :Importer,        "gar/importer"
  autoload :Search,          "gar/search"
  autoload :Utils,           "gar/utils"
  autoload :XmlParser,       "gar/xml_parser"

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def logger
      configuration.logger
    end

    def logger=(value)
      configuration.logger = value
    end
  end
end
