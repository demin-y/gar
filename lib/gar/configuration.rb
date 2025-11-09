# frozen_string_literal: true

module Gar
  class Configuration
    attr_accessor :full_base_dir, :delta_dir, :api_ssl_verify, :api_retry_attempts, :api_retry_timeout,
                  :api_read_timeout, :database_url, :database_schema, :api_all_versions_url,
                  :api_latest_version_url, :import_entities, :entity_options, :batch_size,
                  :parallel_import, :parallel_import_workers, :parallel_import_strategy,
                  :db_retry_max_attempts, :db_retry_base_delay
    attr_writer   :logger

    def initialize
      @database_url             = ENV.fetch("DATABASE_URL", "postgresql://postgres:postgres@localhost:6432/gar_db_dev")
      @database_schema          = "gar"
      @full_base_dir            = "./downloads/full_base"
      @delta_dir                = "./downloads/delta"
      @api_ssl_verify           = true
      @api_retry_attempts       = 3
      @api_retry_timeout        = 5
      @api_read_timeout         = 30
      @api_all_versions_url     = "https://fias.nalog.ru/WebServices/Public/GetAllDownloadFileInfo"
      @api_latest_version_url   = "https://fias.nalog.ru/WebServices/Public/GetLastDownloadFileInfo"
      @import_entities          = Entities.importable_tables
      @batch_size               = 5_000
      @logger                   = nil
      @parallel_import          = true
      @parallel_import_workers  = 4
      @parallel_import_strategy = detect_parallel_strategy
      @db_retry_max_attempts    = 3
      @db_retry_base_delay      = 0.5
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
