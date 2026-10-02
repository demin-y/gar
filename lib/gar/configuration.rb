# frozen_string_literal: true

module Gar
  class Configuration
    # Наборы загружаемых данных. Справочники корня архива грузятся всегда.
    # keep_history — хранить неактуальные записи: true, false или список таблиц.
    MINIMAL_TABLES  = [:address_objects, :addr_obj_params, :adm_hierarchy, :mun_hierarchy, :houses, :house_params].freeze
    EXTENDED_TABLES = (MINIMAL_TABLES + [:steads, :stead_params, :apartments, :apartment_params, :rooms, :room_params,
                                         :reestr_objects, :addr_obj_division]).freeze
    # Почтовый индекс, ОКАТО, ОКТМО, официальное наименование, признаки административного центра
    MINIMAL_PARAM_TYPES = [5, 6, 7, 16, 22, 23].freeze
    PRESETS = {
      # То, что нужно поиску, автодополнению и адресной строке
      minimal:  { tables: MINIMAL_TABLES, param_types: MINIMAL_PARAM_TYPES, keep_history: false },
      # Плюс участки, помещения, реестр GUID, связи разделения и прежние названия улиц
      extended: { tables: EXTENDED_TABLES, param_types: MINIMAL_PARAM_TYPES, keep_history: [:address_objects].freeze },
      # Весь архив: все таблицы, все типы параметров, история записей
      full:     { tables: Schema::REGIONAL.map(&:name).freeze, param_types: :all, keep_history: true }
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
      @parallel_import_workers     = 4
      @parallel_import_strategy    = detect_parallel_strategy
      @import_maintenance_work_mem = "256MB"
      @db_retry_max_attempts       = 3
      @db_retry_base_delay         = 0.5
    end

    def preset=(value)
      value = value.to_sym if value.respond_to?(:to_sym)
      raise ConfigurationError, "Неизвестный набор данных: #{value.inspect}, допустимы #{PRESETS.keys}" unless PRESETS.key?(value)

      @preset = value
    end

    # Таблицы субъектов; по умолчанию — из набора. Дополнить набор: config.tables += %i[steads]
    def tables
      @tables || PRESETS.fetch(preset)[:tables]
    end

    def tables=(names)
      names = Array(names).map(&:to_sym)
      unknown = names - Schema::REGIONAL.map(&:name)
      raise ConfigurationError, "Неизвестные таблицы субъекта: #{unknown.join(', ')} (справочники грузятся всегда)" if unknown.any?

      @tables = names.uniq.freeze
    end

    # Загружаемые иерархии: %i[adm mun], можно оставить одну
    def hierarchies=(names)
      names = Array(names).map(&:to_sym)
      unknown = names - HIERARCHY_TABLES.keys
      raise ConfigurationError, "Неизвестные иерархии: #{unknown.join(', ')}, допустимы adm и mun" if unknown.any?
      raise ConfigurationError, "Нужна хотя бы одна иерархия: adm или mun" if names.empty?

      @hierarchies = names.uniq.freeze
    end

    # Типы параметров объектов (AS_PARAM_TYPES); :all — все типы
    def param_types
      @param_types || PRESETS.fetch(preset)[:param_types]
    end

    def param_types=(value)
      @param_types = value == :all ? :all : Array(value).map { Integer(_1) }.freeze
    end

    def keep_history
      @keep_history.nil? ? PRESETS.fetch(preset)[:keep_history] : @keep_history
    end

    def keep_history=(value)
      @keep_history = value.is_a?(Array) ? value.map(&:to_sym).freeze : value
    end

    def keep_history?(table_name)
      value = keep_history
      value == true || (value.is_a?(Array) && value.include?(table_name))
    end

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
