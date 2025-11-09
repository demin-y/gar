# frozen_string_literal: true

module Gar
  class Database
    include Loggable

    CONNECTION_OK         = PG::CONNECTION_OK
    RETRYABLE_ERRORS      = [PG::UnableToSend, PG::ConnectionBad].freeze
    BASE_DELAY_MULTIPLIER = 2

    attr_reader :conn

    def initialize(conn = nil)
      @conn = conn || self.class.create_connection
    end

    def with_retry(max_attempts: Gar.configuration.db_retry_max_attempts)
      attempts = 0

      begin
        yield @conn
      rescue *RETRYABLE_ERRORS => e
        attempts += 1

        if attempts > max_attempts
          logger.error "Превышено количество попыток переподключения (#{max_attempts}): #{e.message}"
          raise
        end

        delay = Gar.configuration.db_retry_base_delay * (BASE_DELAY_MULTIPLIER**(attempts - 1))
        logger.warn "Ошибка соединения (попытка #{attempts}/#{max_attempts}): #{e.message}. Повтор через #{delay}с"
        sleep(delay)

        reconnect!
        retry
      end
    end

    def ensure_alive!
      @conn.exec("SELECT 1")
    rescue *RETRYABLE_ERRORS
      logger.info("Переподключение к базе данных...")
      reconnect!
    end

    def reconnect!
      @conn.reset
      logger.debug("Соединение сброшено")
    rescue PG::Error => e
      logger.warn("Не удалось сбросить соединение: #{e.message}")
      safe_close
      @conn = self.class.create_connection
    end

    def close
      safe_close
    end

    @mutex = Mutex.new

    class << self
      def connection
        @mutex.synchronize do
          @connection = nil unless connection_valid?(@connection)
          @connection ||= create_connection
        end
      end

      def create_connection(url = nil)
        PG.connect(url || Gar.configuration.database_url)
      end

      def connection_valid?(conn)
        return false unless conn
        return false if conn.finished?

        conn.status == CONNECTION_OK
      rescue PG::Error
        false
      end

      def disconnect!
        @mutex.synchronize do
          @connection&.close unless @connection&.finished?
          @connection = nil
        end
      rescue PG::Error
        @connection = nil
      end
    end

    private

    def safe_close
      @conn&.close unless @conn&.finished?
    rescue PG::Error
      # Соединение уже закрыто
    end
  end
end
