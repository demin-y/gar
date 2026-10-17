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
    include Serializable

    TABLE   = "gar_meta"
    COLUMNS = {
      version_id: "integer NOT NULL", version_date: "date NOT NULL", region_codes: "text[] NOT NULL", tables: "text[] NOT NULL",
      param_types: "integer[]", keep_history: "text[] NOT NULL", prune_hierarchy: "boolean NOT NULL", status: "text NOT NULL",
      imported_at: "timestamptz", paths_built_at: "timestamptz", gem_version: "text NOT NULL"
    }.map { |name, type| Schema::Column.new(name:, type:) }.freeze
    # Статусы: идёт импорт → данные загружены → пути построены, схему можно переключать
    IMPORTING = "importing"
    IMPORTED  = "imported"
    READY     = "ready"
    # Время каждой стадии: статус → колонка
    STAMPS = { IMPORTED => :imported_at, READY => :paths_built_at }.freeze

    def importing? = status == IMPORTING
    def ready? = status == READY

    # Схема загружена (или загружается) так же, как загрузит импорт версии version_id по
    # текущей конфигурации: её можно не загружать заново
    def same_import?(version_id, region_codes:, tables:)
      self.version_id == version_id && settings == self.class.settings(region_codes:, tables:)
    end

    def settings = self.class.normalize(region_codes:, tables:, param_types:, keep_history:, prune_hierarchy:)

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
        settings = settings(region_codes:, tables:)
        values   = {
          version_id: archive.version_id, version_date: archive.version_date.iso8601,
          **settings.transform_values { _1.is_a?(Array) ? Database.array(_1) : _1 },
          status: IMPORTING, gem_version: VERSION
        }
        conn.exec("CREATE TABLE #{qualified(schema)} (#{COLUMNS.map(&:definition).join(', ')})")
        conn.exec_params("INSERT INTO #{qualified(schema)} (#{values.keys.join(', ')}) VALUES (#{(1..values.size).map { "$#{_1}" }.join(', ')})",
                         values.values)
      end

      # Настройки, с которыми импорт по текущей конфигурации загрузит субъекты region_codes и
      # таблицы tables (как в gar_meta, списки отсортированы)
      def settings(region_codes:, tables:)
        config = Gar.configuration
        normalize(region_codes:, tables:, param_types: (config.param_types unless config.param_types == :all),
                  keep_history: config.keep_history, prune_hierarchy: config.prune_hierarchy)
      end

      # Настройки в одном виде для сравнения: таблицы — символы, списки отсортированы
      def normalize(region_codes:, tables:, param_types:, keep_history:, prune_hierarchy:)
        { region_codes: region_codes.sort, tables: tables.map(&:to_sym).sort,
          param_types: param_types&.sort, keep_history: keep_history.sort, prune_hierarchy: }
      end

      # Отмечает, что схема обновлена дельтой до версии архива (Archive)
      def advance(conn, schema, archive)
        conn.exec_params("UPDATE #{qualified(schema)} SET version_id = $1, version_date = $2",
                         [archive.version_id, archive.version_date.iso8601])
      end

      # Переводит схему в статус imported или ready и отмечает время стадии; схему без gar_meta
      # не трогает
      def update(conn, schema, status)
        return unless Database.relation_exists?(conn, qualified(schema))

        conn.exec_params("UPDATE #{qualified(schema)} SET status = $1, #{Schema.quote(STAMPS.fetch(status))} = now()", [status])
      end

      private

      def time(value) = value && Time.iso8601(value)

      def qualified(schema) = Schema.qualify(schema, TABLE)
    end
  end
end
