# frozen_string_literal: true

require "connection_pool"

module Gar
  # Соединения с базой ГАР.
  #
  # Поиск берёт соединения из пула (Gar.with_connection): размер — pool_size, ожидание
  # свободного — pool_timeout, на каждом соединении statement_timeout = search_statement_timeout.
  # Импорт и построение путей открывают свои соединения без statement_timeout
  # (create_connection): их запросы идут часами.
  #
  # Fork: дочерний процесс наследует соединения родителя и не должен ни пользоваться ими, ни
  # закрывать их — PQfinish (в том числе из финализатора при выходе) пошлёт серверу Terminate
  # по общему сокету и оборвёт соединение родителя. Поэтому сразу после fork (хук
  # Process._fork) все соединения, открытые гемом, отбрасываются без PQfinish — сокет
  # перенаправляется в /dev/null, как discard! в Active Record, — а пул создаётся заново
  # при первом обращении.
  module Database
    # Ошибки, при которых база считается недоступной: приложение переключается на ручной ввод
    UNAVAILABLE_ERRORS = [PG::ConnectionBad, PG::UnableToSend, PG::QueryCanceled, ::ConnectionPool::TimeoutError].freeze
    # После них соединение не годится для следующих запросов
    BROKEN_ERRORS = [PG::ConnectionBad, PG::UnableToSend].freeze

    @mutex       = Mutex.new
    @connections = ObjectSpace::WeakMap.new

    class << self
      # Соединение для импорта и построения путей: без statement_timeout, закрывает вызывающий
      def create_connection(statement_timeout: nil)
        config = Gar.configuration
        url    = config.database_url
        raise ConfigurationError, "Не задана база ГАР: укажите config.database_url или переменную GAR_DATABASE_URL" if url.to_s.empty?

        conn = PG.connect(url, connect_timeout: config.connect_timeout, application_name: "gar")
        conn.exec("SET statement_timeout TO #{(statement_timeout * 1000).round}") if statement_timeout
        @connections[conn] = Process.pid
        conn
      end

      # Соединение из пула на время блока. Недоступная база, таймаут запроса или ожидания
      # пула — UnavailableError; сломанное соединение в пул не возвращается
      def with_connection
        pool.with do |conn|
          yield conn
        rescue *BROKEN_ERRORS
          pool.discard_current_connection { close(_1) }
          raise
        end
      rescue *UNAVAILABLE_ERRORS => e
        raise UnavailableError, "База ГАР недоступна: #{e.message.strip}"
      end

      # Закрывает соединения пула; следующий with_connection создаст пул по текущим настройкам
      def disconnect!
        old = @mutex.synchronize { @pool.tap { @pool = nil } }
        old&.shutdown { close(_1) }
      end

      # Вызывается в дочернем процессе сразу после fork: соединения гема отбрасываются,
      # пул будет создан заново
      def after_fork
        @mutex = Mutex.new
        @pool  = nil
        @connections.each_key { discard(_1) }
        @connections = ObjectSpace::WeakMap.new
      end

      # Воркеры параллельного импорта отбрасывают все унаследованные соединения, в том числе
      # переданные приложением в Importer.new: их гем не открывал, но воркер — его процесс.
      # Один раз на процесс; в процессе parent_pid ничего не делает
      def discard_inherited_connections(parent_pid)
        return if [parent_pid, @discarded_in].include?(Process.pid)

        @discarded_in = Process.pid
        ObjectSpace.each_object(PG::Connection) { discard(_1) }
      end

      private

      def pool
        @mutex.synchronize do
          @pool ||=
            ::ConnectionPool.new(size: Gar.configuration.pool_size, timeout: Gar.configuration.pool_timeout,
                                 auto_reload_after_fork: false) do
              create_connection(statement_timeout: Gar.configuration.search_statement_timeout)
            end
        end
      end

      def close(conn)
        conn.close unless conn.finished?
      rescue PG::Error
        nil
      end

      def discard(conn)
        conn.socket_io.reopen(IO::NULL) unless conn.finished?
      rescue PG::Error, IOError, SystemCallError
        nil
      end
    end

    # Хук fork (Ruby ≥ 3.1): срабатывает для fork, Process.fork, Kernel#fork и Process.daemon
    module ForkTracker
      def _fork
        pid = super
        Database.after_fork if pid.zero?
        pid
      end
    end
    Process.singleton_class.prepend(ForkTracker) if Process.respond_to?(:_fork)
  end
end
