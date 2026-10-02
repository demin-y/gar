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
                :status, :imported_at, :paths_built_at, :gem_version) do
      def ready? = status == "ready"

      def loaded?(table) = tables.include?(table.to_sym)
    end

  class Meta
    TABLE   = "gar_meta"
    COLUMNS = {
      version_id: "integer NOT NULL", version_date: "date NOT NULL", region_codes: "text[] NOT NULL", tables: "text[] NOT NULL",
      param_types: "integer[]", keep_history: "text[] NOT NULL", prune_hierarchy: "boolean NOT NULL", status: "text NOT NULL",
      imported_at: "timestamptz", paths_built_at: "timestamptz", gem_version: "text NOT NULL"
    }.freeze
    ARRAY = PG::TextEncoder::Array.new

    class << self
      # Сведения схемы; nil — схема без gar_meta (создана не импортом гема)
      def read(conn, schema)
        return unless exists?(conn, schema)

        row = conn.exec("SELECT row_to_json(m) FROM #{qualified(schema)} m").getvalue(0, 0)
        from_json(JSON.parse(row))
      end

      # Создаёт таблицу со строкой импорта архива (Archive) в статусе importing; настройки
      # берутся из конфигурации
      def create(conn, schema, archive:, region_codes:, tables:)
        config = Gar.configuration
        values = {
          version_id: archive.version_id, version_date: archive.version_date.iso8601, region_codes: ARRAY.encode(region_codes),
          tables: ARRAY.encode(tables.map(&:to_s)),
          param_types: (ARRAY.encode(config.param_types) unless config.param_types == :all),
          keep_history: ARRAY.encode(config.keep_history.map(&:to_s)), prune_hierarchy: config.prune_hierarchy,
          status: "importing", gem_version: VERSION
        }
        conn.exec("CREATE TABLE #{qualified(schema)} (#{COLUMNS.map { |name, type| "#{Schema.quote(name)} #{type}" }.join(', ')})")
        conn.exec_params("INSERT INTO #{qualified(schema)} (#{values.keys.join(', ')}) VALUES (#{placeholders(values.size)})", values.values)
      end

      # Переводит схему в статус status и отмечает время стадии (imported_at, paths_built_at);
      # схему без gar_meta не трогает
      def update(conn, schema, status:, stamp:)
        return unless exists?(conn, schema)

        conn.exec_params("UPDATE #{qualified(schema)} SET status = $1, #{Schema.quote(stamp)} = now()", [status])
      end

      private

      def exists?(conn, schema)
        conn.exec_params("SELECT to_regclass($1)", [qualified(schema)]).getvalue(0, 0)
      end

      def from_json(row)
        new(
          version_id: row["version_id"], version_date: Date.iso8601(row["version_date"]), region_codes: row["region_codes"].freeze,
          tables: row["tables"].map(&:to_sym).freeze, param_types: row["param_types"]&.freeze,
          keep_history: row["keep_history"].map(&:to_sym).freeze, prune_hierarchy: row["prune_hierarchy"], status: row["status"],
          imported_at: row["imported_at"]&.then { Time.iso8601(_1) }, paths_built_at: row["paths_built_at"]&.then { Time.iso8601(_1) },
          gem_version: row["gem_version"]
        )
      end

      def placeholders(count) = (1..count).map { "$#{_1}" }.join(", ")

      def qualified(schema) = "#{Schema.quote(schema)}.#{TABLE}"
    end
  end
end
