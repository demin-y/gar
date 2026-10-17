# frozen_string_literal: true

module Gar
  # Тестовые данные ГАР для спек приложения (Т16):
  #
  #   # spec/rails_helper.rb
  #   require "gar/test_support"
  #   RSpec.configure { |config| config.before(:suite) { Gar::TestSupport.load_fixtures } }
  #
  # Набор — Gar::TestSupport::Sample: Киров с домами (корпус, строение, дробь, литера),
  # Сыктывкар, Москва и цепочка из правил ФНС; GUID объекта — Sample.guid(OBJECTID).
  module TestSupport
    autoload :MemoryArchive, "gar/test_support/memory_archive"
    autoload :Sample,        "gar/test_support/sample"

    # Комментарий схемы, созданной load_fixtures: только такую схему можно заменить
    MARK = "Gar::TestSupport: тестовый набор ГАР"

    class << self
      # Атрибуты элемента XML из записи: NAME="…" с экранированием, nil — без атрибута
      def xml_attributes(record)
        record.filter_map { |name, value| "#{name}=#{value.to_s.encode(xml: :attr)}" unless value.nil? }.join(" ")
      end

      # Загружает набор в schema так же, как импорт архива: таблицы, субъекты и фильтры — по
      # текущим настройкам, затем ключи, индексы, gar_meta и пути. Набор собирается во
      # временной схеме и заменяет schema одним переименованием. Заменяется только схема,
      # созданная load_fixtures, или пустая; схему с другими данными — ConfigurationError.
      # Без conn открывает своё соединение (GAR_DATABASE_URL) и закрывает его. Возвращает schema.
      def load_fixtures(conn = nil, schema: Gar.configuration.database_schema)
        own  = conn.nil?
        conn = Database.create_connection if own
        check_replaceable(conn, schema)

        Database.with_lock(conn, "Загрузка тестового набора в схему #{schema}") do
          staging = Importer.new(conn).import_full_base(Sample.archive, schema: "#{schema}_fixtures_load", parallel: false)
          PathBuilder.new(conn, schema: staging).build
          Schemas.replace(conn, staging, schema) { conn.exec("COMMENT ON SCHEMA #{Schema.quote(schema)} IS #{conn.escape_literal(MARK)}") }
        end
        schema
      ensure
        conn&.close if own
      end

      private

      def check_replaceable(conn, schema)
        row = conn.exec_params(<<~SQL, [schema]).first
          SELECT obj_description(n.oid, 'pg_namespace') AS mark,
                 EXISTS (SELECT 1 FROM pg_class c WHERE c.relnamespace = n.oid) AS used
          FROM pg_namespace n WHERE n.nspname = $1
        SQL
        return if row.nil? || row["mark"] == MARK || row["used"] == "f"

        raise ConfigurationError, "Схема #{schema} содержит данные, которые загрузил не Gar::TestSupport: load_fixtures её не заменит. " \
                                  "Укажите другую схему (schema:) или тестовую базу (GAR_DATABASE_URL)"
      end
    end
  end
end
