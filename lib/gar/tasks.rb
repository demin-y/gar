# frozen_string_literal: true

module Gar
  # Команды rake-задач gar:* (Т15): вызывают операции гема (Gar.download, Gar.import…) и пишут
  # итог и прогресс долгих шагов в io — консоль задачи. Логи гема идут в Gar.logger как обычно.
  # Ошибки — исключения гема: rake печатает их и завершается с ненулевым кодом.
  class Tasks
    STAGES = { download: "Скачивание", import: "Импорт", indexes: "Индексы", paths: "Пути", switch: "Переключение",
               delta: "Дельта" }.freeze
    # Прогресс печатается каждые STEP процентов
    STEP = 10

    def initialize(io = $stdout)
      @io = io
    end

    def download(version_id = nil)
      say "Архив: #{Gar.download(version_id && Integer(version_id), on_progress: progress)}"
    end

    # region_codes — коды субъектов; пустой список — config.region_codes
    def import(region_codes = [])
      schema = Gar.import(region_codes: region_codes.empty? ? nil : region_codes, on_progress: progress)
      if schema == current
        say "Текущая схема #{schema} уже загружена из этой выгрузки с теми же настройками"
      else
        say "Загружена схема #{schema}. Дальше: rake \"gar:build_paths[#{schema}]\" и rake \"gar:switch[#{schema}]\""
      end
    end

    def build_paths(schema = nil)
      schema ||= current
      say "Пути схемы #{schema} построены: #{Gar.build_paths(schema, on_progress: progress)} записей"
    end

    def switch(schema)
      raise ConfigurationError, "Укажите схему: rake \"gar:switch[#{current}_v<версия>]\" (список — rake gar:status)" if schema.to_s.empty?

      Gar.switch(schema, on_progress: progress)
      say "Схема #{schema} стала текущей (#{current})"
    end

    # Обновление для крона: второй запуск, пока идёт первый, не ошибка — задача сообщает и выходит
    def update
      result = Gar.update!(on_progress: progress)
      say case result.kind
          when :none  then "ГАР актуален: версия #{result.to_version}"
          when :delta then "Применены дельты #{result.versions.join(', ')}: версия #{result.from_version} → #{result.to_version}"
          else "Полный импорт: версия #{result.from_version || '—'} → #{result.to_version}"
          end
    rescue LockedError => e
      say "Обновление пропущено: #{e.message}"
    end

    def cleanup
      removed = Gar.cleanup_schemas
      say removed.empty? ? "Лишних схем нет" : "Удалены схемы: #{removed.join(', ')}"
    end

    # Текущая схема, применённые дельты, резервные схемы и схемы импорта — с версией, статусом
    # и местом на диске
    def status
      conn = Database.create_connection
      meta = Meta.read(conn, current)
      return say("Текущей схемы #{current} нет: rake gar:update или gar:download, gar:import, gar:build_paths, gar:switch") unless meta

      say "Текущая схема #{current}: #{describe(conn, current, meta)}"
      regions = meta.region_codes.empty? ? "все" : meta.region_codes.join(", ")
      say "  субъекты: #{regions}; таблицы: #{(meta.tables & Configuration::REGIONAL_TABLES).join(', ')}"
      say "  импорт: #{meta.imported_at || '—'}, пути: #{meta.paths_built_at || '—'}, гем #{meta.gem_version}"
      Delta.history(conn, current, limit: 5).each do |update|
        say "  дельта #{update[:version_id]}: #{update[:applied_at]}, #{update[:upserted]} записей изменено, #{update[:deleted]} удалено"
      end
      (Schemas.backups(conn, current) + Schemas.imports(conn, current)).each { say "#{_1}: #{describe(conn, _1, Meta.read(conn, _1))}" }
    ensure
      conn&.close
    end

    private

    def current = Gar.configuration.database_schema

    def describe(conn, schema, meta)
      state = meta ? "версия #{meta.version_id} (#{meta.version_date}), #{meta.status}" : "без gar_meta"
      "#{state}, #{Utils.format_size(Schemas.size(conn, schema))}"
    end

    # on_progress шагов: строка при смене стадии и каждые STEP процентов (без total — одна)
    def progress
      last = nil
      lambda do |done, total, stage|
        percent = done * 100 / total if total.to_i.positive? # размер скачивания бывает неизвестен
        mark    = [stage, percent&./(STEP)]
        next if mark == last

        last = mark
        say "#{STAGES.fetch(stage, stage)}#{percent ? ": #{percent} %" : '…'}"
      end
    end

    def say(line) = @io.puts(line)
  end
end
