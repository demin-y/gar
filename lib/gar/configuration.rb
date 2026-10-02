# frozen_string_literal: true

require "etc"

module Gar
  class Configuration
    # Наборы загружаемых данных. Справочники корня архива грузятся всегда.
    # keep_history — таблицы, у которых хранятся и неактуальные записи.
    MINIMAL_TABLES  = [:address_objects, :addr_obj_params, :adm_hierarchy, :mun_hierarchy, :houses, :house_params].freeze
    EXTENDED_TABLES = (MINIMAL_TABLES + [:steads, :stead_params, :apartments, :apartment_params, :rooms, :room_params,
                                         :reestr_objects, :addr_obj_division]).freeze
    # Почтовый индекс, ОКАТО, ОКТМО, официальное наименование, признаки административного центра
    MINIMAL_PARAM_TYPES = [5, 6, 7, 16, 22, 23].freeze
    REGIONAL_TABLES = Schema::REGIONAL.map(&:name).freeze
    # Таблицы, где есть неактуальные записи (у них задан фильтр актуальности)
    HISTORY_TABLES  = Schema::REGIONAL.select(&:actual).map(&:name).freeze
    PRESETS = {
      # То, что нужно поиску, автодополнению и адресной строке
      minimal:  { tables: MINIMAL_TABLES, param_types: MINIMAL_PARAM_TYPES, keep_history: [].freeze },
      # Плюс участки, помещения, реестр GUID, связи разделения и прежние названия улиц
      extended: { tables: EXTENDED_TABLES, param_types: MINIMAL_PARAM_TYPES, keep_history: [:address_objects].freeze },
      # Весь архив: все таблицы, все типы параметров, история записей
      full:     { tables: REGIONAL_TABLES, param_types: :all, keep_history: HISTORY_TABLES }
    }.freeze
    HIERARCHY_TABLES = { adm: :adm_hierarchy, mun: :mun_hierarchy }.freeze

    attr_accessor :full_base_dir, :delta_dir, :api_ssl_verify, :api_retry_attempts, :api_retry_timeout,
                  :api_read_timeout, :database_url, :database_schema, :api_all_versions_url,
                  :api_latest_version_url, :parallel_import, :parallel_import_workers, :parallel_import_strategy,
                  :import_maintenance_work_mem, :db_retry_max_attempts, :db_retry_base_delay
    attr_reader   :preset, :hierarchies
    attr_writer   :logger

    def initialize
      @database_url                = ENV.fetch("DATABASE_URL", "postgresql://postgres:postgres@localhost:6432/gar_db_dev")
      @database_schema             = "gar"
      @full_base_dir               = "./downloads/full_base"
      @delta_dir                   = "./downloads/delta"
      @api_ssl_verify              = true
      @api_retry_attempts          = 3
      @api_retry_timeout           = 5
      @api_read_timeout            = 30
      @api_all_versions_url        = "https://fias.nalog.ru/WebServices/Public/GetAllDownloadFileInfo"
      @api_latest_version_url      = "https://fias.nalog.ru/WebServices/Public/GetLastDownloadFileInfo"
      @preset                      = :minimal
      @hierarchies                 = HIERARCHY_TABLES.keys
      @logger                      = nil
      @parallel_import             = true
      @parallel_import_workers     = [Etc.nprocessors, 4].min
      @parallel_import_strategy    = detect_parallel_strategy
      @import_maintenance_work_mem = nil
      @db_retry_max_attempts       = 3
      @db_retry_base_delay         = 0.5
    end

    # Сначала набор, затем тонкая настройка: явно заданные tables, param_types и keep_history
    # смена набора не меняет
    def preset=(value)
      value = value.to_sym if value.respond_to?(:to_sym)
      raise ConfigurationError, "Неизвестный набор данных: #{value.inspect}, допустимы #{PRESETS.keys}" unless PRESETS.key?(value)

      @preset = value
    end

    # Таблицы субъектов; по умолчанию — из набора. Дополнить набор: config.tables += [:steads]
    def tables = @tables || from_preset(:tables)

    def tables=(names)
      @tables = symbols(names, REGIONAL_TABLES) { "Неизвестные таблицы субъекта: #{_1.join(', ')} (справочники грузятся всегда)" }
    end

    # Загружаемые иерархии: [:adm, :mun], можно оставить одну
    def hierarchies=(names)
      names = symbols(names, HIERARCHY_TABLES.keys) { "Неизвестные иерархии: #{_1.join(', ')}, допустимы adm и mun" }
      raise ConfigurationError, "Нужна хотя бы одна иерархия: adm или mun" if names.empty?

      @hierarchies = names
    end

    # Типы параметров объектов (AS_PARAM_TYPES); :all — все типы
    def param_types = @param_types || from_preset(:param_types)

    def param_types=(value)
      @param_types = value == :all ? :all : Array(value).map { param_type(_1) }.freeze
    end

    # Таблицы, у которых хранятся и неактуальные записи. Задаётся true (все), false или списком;
    # nil — как в наборе
    def keep_history = @keep_history || from_preset(:keep_history)

    def keep_history=(value)
      @keep_history =
        case value
        when true  then HISTORY_TABLES
        when false then [].freeze
        when nil   then nil
        else symbols(value, HISTORY_TABLES) { "Нет неактуальных записей у таблиц: #{_1.join(', ')}" }
        end
    end

    def keep_history?(table_name) = keep_history.include?(table_name)

    # Таблицы импорта: справочники корня и выбранные таблицы субъектов без отключённых иерархий
    def import_tables
      skipped = HIERARCHY_TABLES.except(*hierarchies).values
      Schema::DICTIONARIES + (tables - skipped).map { Schema.fetch(_1) }
    end

    def logger
      @logger = resolve_logger(@logger) unless resolved_logger?(@logger)
      @logger
    end

    private

    def from_preset(key) = PRESETS.fetch(preset)[key]

    def param_type(value)
      Integer(value, exception: false) or raise ConfigurationError, "Тип параметра — число: #{value.inspect}"
    end

    # Список имён без повторов; неизвестные имена — ConfigurationError с сообщением из блока
    def symbols(names, allowed)
      names   = Array(names).map(&:to_sym).uniq.freeze
      unknown = names - allowed
      raise ConfigurationError, yield(unknown) if unknown.any?

      names
    end

    def detect_parallel_strategy
      case RUBY_PLATFORM
      when /darwin|mingw|mswin|cygwin/i
        :threads # macOS/Windows: fork issues or not supported
      else
        :processes # Linux/Unix: best performance and memory isolation
      end
    end

    def resolved_logger?(value)
      value.is_a?(::Logger) || value.is_a?(NullLogger) || (defined?(ActiveSupport::Logger) && value.is_a?(ActiveSupport::Logger))
    end

    def resolve_logger(value)
      case value
      when false
        NullLogger.new
      when nil
        default_logger
      else
        value
      end
    end

    def default_logger
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger
      else
        Logger.new($stdout, level: Logger::INFO)
      end
    end
  end
end
