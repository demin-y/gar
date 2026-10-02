# frozen_string_literal: true

require "connection_pool"

module Gar
  # Соединения с базой ГАР.
  #
  # Поиск берёт соединения из пула (Gar.with_connection): размер — pool_size, ожидание
  # свободного — pool_timeout, у каждого соединения statement_timeout = search_statement_timeout.
  # Пул пересоздаётся, когда меняются эти настройки или адрес базы. Импорт и построение путей
  # открывают свои соединения без statement_timeout (create_connection): их запросы идут часами.
  #
  # Fork: дочерний процесс наследует соединения родителя и не должен ни пользоваться ими, ни
  # закрывать их — PQfinish (в том числе из финализатора при выходе) пошлёт серверу Terminate
  # по общему сокету и оборвёт соединение родителя. Поэтому сразу после fork (хук
  # Process._fork) все соединения гема — открытые им и переданные ему (adopt) — отбрасываются
  # без PQfinish: сокет перенаправляется в /dev/null, как discard! в Active Record.
  module Database
    # Ошибки, при которых база считается недоступной: приложение переключается на ручной ввод
    UNAVAILABLE_ERRORS = [PG::ConnectionBad, PG::UnableToSend, PG::QueryCanceled, ::ConnectionPool::TimeoutError].freeze
    # После них соединение не годится для следующих запросов
    BROKEN_ERRORS = [PG::ConnectionBad, PG::UnableToSend].freeze
    ARRAY = PG::TextEncoder::Array.new
    # Соединения, которые держат блокировку with_lock (для повторного входа)
    HELD_LOCKS = ObjectSpace::WeakKeyMap.new

    @mutex       = Mutex.new
    @connections = ObjectSpace::WeakMap.new

    class << self
      # Новое соединение; закрывает вызывающий. statement_timeout (с) — значение сессии по
      # умолчанию: передаётся при подключении и переживает RESET ALL
      def create_connection(statement_timeout: nil)
        config = Gar.configuration
        url    = config.database_url
        raise ConfigurationError, "Не задана база ГАР: укажите config.database_url или переменную GAR_DATABASE_URL" if url.to_s.empty?

        options = { connect_timeout: config.connect_timeout, application_name: "gar" }
        options[:options] = "-c statement_timeout=#{(statement_timeout * 1000).round}" if statement_timeout
        adopt(PG.connect(url, **options))
      end

      # Соединение, которое гем не трогает после fork, — в том числе переданное приложением
      # в Importer или PathBuilder
      def adopt(conn)
        @connections[conn] = true
        conn
      end

      # Соединение conn или из пула на время блока. Недоступная база, таймаут запроса или
      # ожидания пула — UnavailableError; сломанное соединение в пул не возвращается
      def with_connection(conn = nil, &)
        translate_errors { conn ? yield(conn) : with_pooled(&) }
      end

      # Есть ли таблица или индекс (qualified_name — уже в кавычках); хватает права SELECT
      def relation_exists?(conn, qualified_name)
        !conn.exec_params("SELECT to_regclass($1)", [qualified_name]).getvalue(0, 0).nil?
      end

      # Какие из таблиц и индексов есть (имена — уже в кавычках), одним запросом
      def existing_relations(conn, qualified_names)
        conn.exec_params("SELECT n FROM unnest($1::text[]) n WHERE to_regclass(n) IS NOT NULL", [array(qualified_names)]).column_values(0)
      end

      # Блокировка изменяющих операций (импорт, пути, переключение, очистка схем, дельты) на
      # время блока: advisory lock сессии conn с ключом по config.database_schema; занята другой
      # сессией — LockedError. Повторный вход в той же сессии к базе не обращается: вложенный
      # вызов внутри транзакции не снимает блокировку в прерванной транзакции. Если conn уже в
      # транзакции (её открыло приложение), блокировка берётся на транзакцию и снимается при её
      # COMMIT или ROLLBACK — снять её запросом в прерванной транзакции нельзя. Блокировка
      # снимается и при обрыве соединения
      def with_lock(conn, operation)
        return yield if HELD_LOCKS[conn]

        key  = "gar:#{Gar.configuration.database_schema}"
        xact = conn.transaction_status == PG::PQTRANS_INTRANS
        unless conn.exec_params("SELECT pg_try_advisory#{'_xact' if xact}_lock(hashtext($1))", [key]).getvalue(0, 0) == "t"
          raise LockedError, "#{operation}: базу ГАР (схема #{Gar.configuration.database_schema}) уже изменяет другой процесс"
        end

        HELD_LOCKS[conn] = true
        begin
          yield
        ensure
          HELD_LOCKS.delete(conn)
          conn.exec_params("SELECT pg_advisory_unlock(hashtext($1))", [key]) unless xact || conn.finished?
        end
      end

      # Блок в транзакции conn; если она уже открыта — в ней же: вложенный BEGIN … COMMIT
      # завершил бы внешнюю транзакцию раньше времени
      def transaction(conn, &) = conn.transaction_status == PG::PQTRANS_INTRANS ? yield(conn) : conn.transaction(&)

      # Значение параметра-массива: $1::bigint[] и т. п.
      def array(values) = ARRAY.encode(values)

      # Закрывает соединения пула; следующий with_connection создаст новый
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

      private

      def translate_errors
        yield
      rescue *UNAVAILABLE_ERRORS => e
        raise UnavailableError, "База ГАР недоступна: #{e.message.strip}"
      end

      def with_pooled
        current = pool
        current.with do |conn|
          yield conn
        rescue *BROKEN_ERRORS
          current.discard_current_connection { close(_1) }
          raise
        end
      end

      # Пул по текущим настройкам; без блокировки, пока они не менялись
      def pool
        key     = pool_key
        current = @pool
        return current if current && @pool_key == key

        old = nil
        current =
          @mutex.synchronize do
            unless @pool && @pool_key == key
              old       = @pool
              @pool_key = key
              @pool     = new_pool(*key)
            end
            @pool
          end
        old&.shutdown { close(_1) }
        current
      end

      def pool_key
        config = Gar.configuration
        [config.database_url, config.pool_size, config.pool_timeout, config.search_statement_timeout, config.connect_timeout]
      end

      def new_pool(_url, size, timeout, statement_timeout, _connect_timeout)
        ::ConnectionPool.new(size:, timeout:, auto_reload_after_fork: false) { create_connection(statement_timeout:) }
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
    Process.singleton_class.prepend(ForkTracker)
  end
end
