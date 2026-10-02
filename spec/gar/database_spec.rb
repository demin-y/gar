# frozen_string_literal: true

RSpec.describe Gar::Database do
  def backend_pid(conn) = conn.exec("SELECT pg_backend_pid()").getvalue(0, 0)

  describe "настройка" do
    it "без адреса базы бросает ConfigurationError с подсказкой при первом обращении" do
      Gar.configure { _1.database_url = nil }

      expect { Gar::Search.new.search_houses("Ленина 10") }.to raise_error(Gar::ConfigurationError, /GAR_DATABASE_URL/)
    end

    it "берёт адрес из GAR_DATABASE_URL, а не из DATABASE_URL приложения" do
      stub_const("ENV", ENV.to_h.merge("DATABASE_URL" => "postgresql://app/app_db", "GAR_DATABASE_URL" => "postgresql://gar/gar_db"))

      expect(Gar::Configuration.new.database_url).to eq("postgresql://gar/gar_db")
      stub_const("ENV", ENV.to_h.except("GAR_DATABASE_URL"))
      expect(Gar::Configuration.new.database_url).to be_nil
    end
  end

  describe "пул соединений", :db do
    it "выдаёт соединения пула с statement_timeout поиска, а импорту — без таймаута" do
      Gar.configure { _1.search_statement_timeout = 0.5 }

      expect(Gar.with_connection { _1.exec("SHOW statement_timeout").getvalue(0, 0) }).to eq("500ms")
      conn = described_class.create_connection
      expect(conn.exec("SHOW statement_timeout").getvalue(0, 0)).to eq("0")
    ensure
      conn&.close
    end

    it "пересоздаёт пул, когда меняются его настройки" do
      expect(Gar.with_connection { _1.exec("SHOW statement_timeout").getvalue(0, 0) }).to eq("1s")

      Gar.configuration.search_statement_timeout = 2

      expect(Gar.with_connection { _1.exec("SHOW statement_timeout").getvalue(0, 0) }).to eq("2s")
    end

    it "раздаёт потокам разные соединения в пределах pool_size" do
      Gar.configure { _1.pool_size = 3 }
      search = Gar::Search.new

      pids = Array.new(8) do
        Thread.new { Gar.with_connection { |conn| conn.exec("SELECT pg_sleep(0.05)") && backend_pid(conn) } }
      end.map(&:value)
      results = Array.new(8) { Thread.new { search.search_address_objects("Воровского").size } }.map(&:value)

      expect(pids.uniq.size).to be_between(2, 3)
      expect(results.uniq).to eq([1])
    end

    it "превращает таймаут запроса и ожидания пула в UnavailableError" do
      Gar.configure do |config|
        config.pool_size                = 1
        config.pool_timeout             = 0.1
        config.search_statement_timeout = 0.1
      end

      expect { Gar.with_connection { _1.exec("SELECT pg_sleep(1)") } }.to raise_error(Gar::UnavailableError, /statement timeout/)
      holder = Thread.new { Gar.with_connection { sleep 0.5 } }
      sleep 0.1
      expect { Gar.with_connection { nil } }.to raise_error(Gar::UnavailableError)
      holder.join
      expect(Gar.with_connection { _1.exec("SELECT 1").getvalue(0, 0) }).to eq("1")
    end

    it "не возвращает в пул оборванное соединение" do
      Gar.configure { _1.pool_size = 1 }
      first = Gar.with_connection { backend_pid(_1) }
      db_connection.exec_params("SELECT pg_terminate_backend($1)", [first])

      expect { Gar.with_connection { _1.exec("SELECT 1") } }.to raise_error(Gar::UnavailableError)
      expect(Gar.with_connection { backend_pid(_1) }).not_to eq(first)
    end

    it "после fork ребёнок работает со своим соединением, а соединение родителя остаётся живым" do
      skip "fork недоступен" unless Process.respond_to?(:fork)
      parent = Gar.with_connection { backend_pid(_1) }
      reader, writer = IO.pipe

      child =
        fork do
          TestDatabase.discard_after_fork
          reader.close
          writer.write(Gar.with_connection { backend_pid(_1) })
          writer.close
          exit!(0) # без at_exit RSpec; финализаторы соединений всё равно отработают при выходе
        end
      writer.close
      Process.wait(child)

      expect(reader.read).not_to eq(parent)
      expect(Gar.with_connection { backend_pid(_1) }).to eq(parent)
    end

    it "соединение родителя переживает выход ребёнка, который не трогал базу" do
      skip "fork недоступен" unless Process.respond_to?(:fork)
      parent = Gar.with_connection { backend_pid(_1) }

      # Обычный выход: финализаторы унаследованных соединений отрабатывают (вывод at_exit RSpec — в /dev/null)
      Process.wait(fork do
        TestDatabase.discard_after_fork
        $stdout.reopen(IO::NULL)
        exit(0)
      end)

      expect(Gar.with_connection { backend_pid(_1) }).to eq(parent)
    end
  end

  describe "Gar.available?", :db do
    it "true, когда текущая схема есть и пути в ней построены" do
      expect(Gar.available?).to be(true)
    end

    it "false без текущей схемы или пока пути не построены" do
      schema = isolated_schema("gar_empty")
      db_connection.exec("CREATE SCHEMA #{schema}")
      db_connection.exec(Gar::Schema.fetch(:address_objects).create_sql(schema))

      Gar.configure { _1.database_schema = schema }
      expect(Gar.available?).to be(false)
      db_connection.exec("CREATE TABLE #{schema}.gar_meta AS SELECT * FROM gar.gar_meta")
      db_connection.exec("UPDATE #{schema}.gar_meta SET status = 'imported'")
      expect(Gar.available?).to be(false)
      Gar.configure { _1.database_schema = "#{schema}_нет" }
      expect(Gar.available?).to be(false)
    end

    it "false за connect_timeout, если база недоступна; поиск бросает UnavailableError" do
      Gar.configure { _1.database_url = "postgresql://postgres@127.0.0.1:1/gar" }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(Gar.available?).to be(false)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < Gar.configuration.connect_timeout
      expect { Gar::Search.new.search_houses("Ленина") }.to raise_error(Gar::UnavailableError, /недоступна/)
    end
  end
end
