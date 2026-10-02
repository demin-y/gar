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

    # База доступна и готова к поиску: текущая схема есть и пути в ней построены (их
    # полнотекстовые индексы PathBuilder создаёт последними). Запрос только к каталогу,
    # хватает права SELECT; ошибка соединения или прав — false
    def available?
      schema  = configuration.database_schema
      markers = Configuration::HIERARCHY_TABLES.keys.map { "#{Schema.quote(schema)}.#{Schema.quote("idx_address_objects_full_#{_1}_path_tsv")}" }
      with_connection do |conn|
        conn.exec_params(<<~SQL, [Schema.fetch(:address_objects).qualified_name(schema), *markers]).getvalue(0, 0) == "t"
          SELECT to_regclass($1) IS NOT NULL AND (#{markers.each_index.map { "to_regclass($#{_1 + 2}) IS NOT NULL" }.join(' OR ')})
        SQL
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

    # Событие name через ActiveSupport::Notifications, если он загружен; в payload блок
    # дописывает итоги (например, число результатов)
    def instrument(name, payload = {}, &)
      return yield(payload) unless defined?(ActiveSupport::Notifications)

      ActiveSupport::Notifications.instrument(name, payload, &)
    end
  end
end
