# frozen_string_literal: true

require "pg"
require "logger"
require_relative "gar/version"
require_relative "gar/errors"

module Gar
  autoload :AddressObject,   "gar/results"
  autoload :House,           "gar/results"
  autoload :Archive,         "gar/archive"
  autoload :Configuration,   "gar/configuration"
  autoload :Loggable,        "gar/loggable"
  autoload :Meta,            "gar/meta"
  autoload :Database,        "gar/database"
  autoload :Downloader,      "gar/downloader"
  autoload :Importer,        "gar/importer"
  autoload :PathBuilder,     "gar/path_builder"
  autoload :Schema,          "gar/schema"
  autoload :Search,          "gar/search"
  autoload :TestSupport,     "gar/test_support"
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
      Database.disconnect!
      @configuration = nil
    end

    # Соединение из пула поиска на время блока; недоступная база — UnavailableError
    def with_connection(&) = Database.with_connection(&)

    # База доступна и готова к поиску: в текущей схеме импорт завершён и пути построены
    # (gar_meta.status = ready). Хватает права SELECT; ошибка соединения или прав — false
    def available?
      with_connection { |conn| Meta.read(conn, configuration.database_schema)&.status == "ready" }
    rescue UnavailableError, PG::Error => e
      logger.warn "База ГАР недоступна: #{e.message.strip}"
      false
    end

    def logger
      configuration.logger
    end

    def logger=(value)
      configuration.logger = value
    end

    # Событие name через ActiveSupport::Notifications, если он загружен; в payload блок
    # дописывает итоги (например, число результатов)
    def instrument(name, payload = {}, &)
      return yield(payload) unless defined?(ActiveSupport::Notifications)

      ActiveSupport::Notifications.instrument(name, payload, &)
    end
  end
end
