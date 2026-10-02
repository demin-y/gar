# frozen_string_literal: true

require "date"
require "json"
require "time"

module Gar
  # Служебная таблица gar_meta схемы ГАР (одна строка): версия выгрузки, с какими настройками
  # загружены данные и на какой стадии схема. Функции гема и дельты смотрят сюда, а не в текущую
  # конфигурацию: схема могла быть загружена с другими настройками.
  #
  # status — importing (идёт импорт), imported (данные, ключи и индексы готовы), ready (пути
  # построены). region_codes — запрошенные субъекты, пустой список — все; param_types — nil,
  # если загружены все типы параметров.
  Meta =
    Data.define(:version_id, :version_date, :region_codes, :tables, :param_types, :keep_history, :prune_hierarchy,
                :status, :imported_at, :paths_built_at, :gem_version)

  class Meta
    TABLE   = "gar_meta"
    COLUMNS = {
      version_id: "integer NOT NULL", version_date: "date NOT NULL", region_codes: "text[] NOT NULL", tables: "text[] NOT NULL",
      param_types: "integer[]", keep_history: "text[] NOT NULL", prune_hierarchy: "boolean NOT NULL", status: "text NOT NULL",
      imported_at: "timestamptz", paths_built_at: "timestamptz", gem_version: "text NOT NULL"
    }.map { |name, type| Schema::Column.new(name:, type:) }.freeze
    # Время каждой стадии: статус → колонка
    STAMPS = { "imported" => :imported_at, "ready" => :paths_built_at }.freeze

    class << self
      # Сведения схемы; nil — схема без gar_meta (создана не импортом гема)
      def read(conn, schema)
        return unless Database.relation_exists?(conn, qualified(schema))

        row = JSON.parse(conn.exec("SELECT row_to_json(m) FROM #{qualified(schema)} m").getvalue(0, 0))
        new(**row.transform_keys(&:to_sym),
            version_date: Date.iso8601(row["version_date"]), tables: row["tables"].map(&:to_sym), keep_history: row["keep_history"].map(&:to_sym),
            imported_at: time(row["imported_at"]), paths_built_at: time(row["paths_built_at"]))
      end

      # Создаёт таблицу со строкой импорта архива (Archive) в статусе importing; настройки
      # берутся из конфигурации
      def create(conn, schema, archive:, region_codes:, tables:)
        config = Gar.configuration
        values = {
          version_id: archive.version_id, version_date: archive.version_date.iso8601, region_codes: Database.array(region_codes),
          tables: Database.array(tables.map(&:to_s)),
          param_types: (Database.array(config.param_types) unless config.param_types == :all),
          keep_history: Database.array(config.keep_history.map(&:to_s)), prune_hierarchy: config.prune_hierarchy,
          status: "importing", gem_version: VERSION
        }
        conn.exec("CREATE TABLE #{qualified(schema)} (#{COLUMNS.map(&:definition).join(', ')})")
        conn.exec_params("INSERT INTO #{qualified(schema)} (#{values.keys.join(', ')}) VALUES (#{(1..values.size).map { "$#{_1}" }.join(', ')})",
                         values.values)
      end

      # Переводит схему в статус imported или ready и отмечает время стадии; схему без gar_meta
      # не трогает
      def update(conn, schema, status)
        return unless Database.relation_exists?(conn, qualified(schema))

        conn.exec_params("UPDATE #{qualified(schema)} SET status = $1, #{Schema.quote(STAMPS.fetch(status))} = now()", [status])
      end

      private

      def time(value) = value && Time.iso8601(value)

      def qualified(schema) = "#{Schema.quote(schema)}.#{TABLE}"
    end
  end
end
