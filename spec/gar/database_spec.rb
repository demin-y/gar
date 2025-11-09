# frozen_string_literal: true

RSpec.describe Gar::Database do
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }

  before do
    allow(Gar).to receive(:logger).and_return(logger)
  end

  after do
    # Сброс singleton-соединения между тестами
    described_class.instance_variable_set(:@connection, nil)
  end

  describe ".connection_valid?" do
    it "возвращает false для nil" do
      expect(described_class.connection_valid?(nil)).to be false
    end

    it "возвращает true для валидного соединения" do
      conn = instance_double(PG::Connection, status: PG::CONNECTION_OK, finished?: false)
      expect(described_class.connection_valid?(conn)).to be true
    end

    it "возвращает false для закрытого соединения" do
      conn = instance_double(PG::Connection, status: PG::CONNECTION_OK, finished?: true)
      expect(described_class.connection_valid?(conn)).to be false
    end

    it "возвращает false при PG::Error" do
      conn = instance_double(PG::Connection, finished?: false)
      allow(conn).to receive(:status).and_raise(PG::Error)
      expect(described_class.connection_valid?(conn)).to be false
    end
  end

  describe "#reconnect!" do
    context "когда reset успешен" do
      it "сохраняет то же соединение" do
        conn = instance_double(PG::Connection)
        allow(conn).to receive(:reset)

        db = described_class.new(conn)
        db.reconnect!

        expect(db.conn).to eq(conn)
        expect(conn).to have_received(:reset)
      end
    end

    context "когда reset не удался" do
      it "создаёт новое соединение" do
        old_conn = instance_double(PG::Connection, finished?: false)
        new_conn = instance_double(PG::Connection)
        allow(old_conn).to receive(:reset).and_raise(PG::Error, "reset failed")
        allow(old_conn).to receive(:close)
        allow(described_class).to receive(:create_connection).and_return(new_conn)

        db = described_class.new(old_conn)
        db.reconnect!

        expect(db.conn).to eq(new_conn)
        expect(old_conn).to have_received(:close)
      end
    end
  end

  describe "#ensure_alive!" do
    it "не переподключается при живом соединении" do
      conn = instance_double(PG::Connection)
      allow(conn).to receive(:exec).with("SELECT 1")

      db = described_class.new(conn)
      db.ensure_alive!

      expect(conn).to have_received(:exec).with("SELECT 1")
    end

    it "переподключается при PG::ConnectionBad" do
      conn = instance_double(PG::Connection)
      allow(conn).to receive(:exec).with("SELECT 1").and_raise(PG::ConnectionBad)
      allow(conn).to receive(:reset)

      db = described_class.new(conn)
      db.ensure_alive!

      expect(conn).to have_received(:reset)
    end

    it "переподключается при PG::UnableToSend" do
      conn = instance_double(PG::Connection)
      allow(conn).to receive(:exec).with("SELECT 1").and_raise(PG::UnableToSend)
      allow(conn).to receive(:reset)

      db = described_class.new(conn)
      db.ensure_alive!

      expect(conn).to have_received(:reset)
    end
  end

  describe "#with_retry" do
    let(:conn) { instance_double(PG::Connection) }
    let(:db) { described_class.new(conn) }

    before do
      allow(conn).to receive(:reset)
    end

    it "выполняет блок без retry при успехе" do
      result = db.with_retry(&:object_id)

      expect(result).to eq(conn.object_id)
    end

    it "переподключается и повторяет при PG::ConnectionBad" do
      call_count = 0
      allow(db).to receive(:sleep)

      result =
        db.with_retry do |c|
          call_count += 1
          raise PG::ConnectionBad, "connection lost" if call_count == 1

          c
        end

      expect(result).to eq(conn)
      expect(call_count).to eq(2)
    end

    it "переподключается и повторяет при PG::UnableToSend" do
      call_count = 0
      allow(db).to receive(:sleep)

      db.with_retry do
        call_count += 1
        raise PG::UnableToSend, "unable to send" if call_count == 1
      end

      expect(call_count).to eq(2)
    end

    it "выбрасывает исключение после превышения max_attempts" do
      allow(db).to receive(:sleep)

      expect do
        db.with_retry(max_attempts: 2) do
          raise PG::ConnectionBad, "connection lost"
        end
      end.to raise_error(PG::ConnectionBad)
    end

    it "использует экспоненциальный backoff" do
      allow(db).to receive(:sleep)

      call_count = 0
      begin
        db.with_retry(max_attempts: 3) do
          call_count += 1
          raise PG::ConnectionBad, "connection lost"
        end
      rescue PG::ConnectionBad
        # ожидаемо
      end

      expect(db).to have_received(:sleep).with(0.5).ordered
      expect(db).to have_received(:sleep).with(1.0).ordered
      expect(db).to have_received(:sleep).with(2.0).ordered
    end

    it "обновляет @conn при reconnect" do
      new_conn = instance_double(PG::Connection)
      allow(conn).to receive(:reset).and_raise(PG::Error, "reset failed")
      allow(conn).to receive_messages(finished?: false, close: nil)
      allow(described_class).to receive(:create_connection).and_return(new_conn)
      allow(db).to receive(:sleep)

      call_count = 0
      db.with_retry do
        call_count += 1
        raise PG::ConnectionBad, "connection lost" if call_count == 1
      end

      expect(db.conn).to eq(new_conn)
    end

    it "не ловит другие PG::Error" do
      expect do
        db.with_retry do
          raise PG::Error, "some other error"
        end
      end.to raise_error(PG::Error, "some other error")
    end
  end

  describe "#close" do
    it "закрывает соединение" do
      conn = instance_double(PG::Connection, finished?: false)
      allow(conn).to receive(:close)

      db = described_class.new(conn)
      db.close

      expect(conn).to have_received(:close)
    end

    it "не падает если соединение уже закрыто" do
      conn = instance_double(PG::Connection, finished?: true)

      db = described_class.new(conn)
      expect { db.close }.not_to raise_error
    end
  end
end
