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

    # Новые настройки действуют на соединения, открытые после блока: пул поиска закрывается
    def configure
      yield(configuration)
      Database.disconnect!
    end

    # Возвращает настройки к значениям по умолчанию (тесты, перезагрузка кода в Rails)
    def reset_configuration!
      Database.disconnect!
      @configuration = nil
    end

    # Соединение из пула поиска на время блока; недоступная база — UnavailableError
    def with_connection(&) = Database.with_connection(&)

    # База доступна и готова к поиску: текущая схема есть и пути в ней построены. Для
    # проверки хватает права SELECT; ошибка соединения или прав — false
    def available?
      with_connection do |conn|
        table = "#{Schema.quote(configuration.database_schema)}.address_objects"
        next false unless conn.exec_params("SELECT to_regclass($1)", [table]).getvalue(0, 0)

        conn.exec("SELECT EXISTS (SELECT FROM #{table} WHERE full_adm_path IS NOT NULL OR full_mun_path IS NOT NULL)").getvalue(0, 0) == "t"
      end
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
  end
end
