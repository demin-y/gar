# frozen_string_literal: true

require "pg"
require "logger"
require_relative "gar/version"
require_relative "gar/errors"

module Gar
  autoload :Address,         "gar/results"
  autoload :AddressBuilder,  "gar/address_builder"
  autoload :AddressObject,   "gar/results"
  autoload :Autocomplete,    "gar/autocomplete"
  autoload :House,           "gar/results"
  autoload :HouseMatch,      "gar/results"
  autoload :HouseMatcher,    "gar/house_matcher"
  autoload :HouseNumber,     "gar/house_number"
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
  autoload :Serializable,    "gar/results"
  autoload :Suggestion,      "gar/results"
  autoload :Synonyms,        "gar/synonyms"
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
      Synonyms.reset!
      @configuration = nil
    end

    # Автодополнение одной строки ввода (Т7): «Киров, Ленина 10б» → список Gar::Suggestion,
    # дома с точным номером первыми, затем с номером-префиксом, затем улицы. Границы —
    # region_codes: и within: (GUID города или района), как у Gar::Search
    def autocomplete(query, hierarchy: nil, region_codes: nil, within: nil, limit: 10)
      Autocomplete.new.call(query, hierarchy:, region_codes:, within:, limit:)
    end

    # Разобранный адрес объекта или дома по GUID (Т8) — Gar::Address со строкой по правилам ФНС;
    # nil, если действующего объекта с таким GUID нет
    def address(guid, hierarchy: nil) = AddressBuilder.new.call(guid, hierarchy:)

    # Дом из старой записи адреса по GUID улицы и номеру (Т11) — Gar::HouseMatch со статусом
    # :exact, :fuzzy или :none и альтернативами; см. Gar::HouseMatcher
    def match_house(street_guid:, number:, letter: nil, building: nil, structure: nil, hierarchy: nil)
      HouseMatcher.new.call(street_guid:, number:, letter:, building:, structure:, hierarchy:)
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
