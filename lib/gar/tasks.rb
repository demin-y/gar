# frozen_string_literal: true

module Gar
  # Команды rake-задач gar:* (Т15): вызывают операции гема (Gar.download, Gar.import…) и пишут
  # итог и прогресс долгих шагов в $stdout — консоль задачи. Логи гема идут в Gar.logger как обычно.
  # Ошибки — исключения гема: rake печатает их и завершается с ненулевым кодом.
  class Tasks
    STAGES = { download: "Скачивание", import: "Импорт", indexes: "Индексы", paths: "Пути", switch: "Переключение",
               delta: "Дельта" }.freeze
    # Прогресс печатается каждые STEP процентов
    STEP = 10

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
      if schema.to_s.empty?
        raise ConfigurationError, "Укажите схему: rake \"gar:switch[#{Schemas.import_name(current, '<версия>')}]\" (список — rake gar:status)"
      end

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

    # Текущая схема, её последние дельты, резервные схемы и схемы импорта (Gar.status)
    def status
      status = Gar.status
      meta   = status.current&.meta
      return say("Текущей схемы #{current} нет: rake gar:update или gar:download, gar:import, gar:build_paths, gar:switch") unless meta

      regions = meta.region_codes.empty? ? "все" : meta.region_codes.join(", ")
      say "Текущая схема #{describe(status.current)}"
      say "  субъекты: #{regions}; таблицы: #{(meta.tables & Configuration::REGIONAL_TABLES).join(', ')}"
      say "  импорт: #{meta.imported_at || '—'}, пути: #{meta.paths_built_at || '—'}, гем #{meta.gem_version}"
      status.updates.each { say "  дельта #{_1.version_id}: #{_1.applied_at}, #{_1.upserted} записей изменено, #{_1.deleted} удалено" }
      (status.backups + status.imports).each { say describe(_1) }
    end

    private

    def current = Gar.configuration.database_schema

    def describe(schema)
      meta  = schema.meta
      state = meta ? "версия #{meta.version_id} (#{meta.version_date}), #{meta.status}" : "без gar_meta"
      "#{schema.name}: #{state}, #{Utils.format_size(schema.size)}"
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

    def say(line) = $stdout.puts(line)
  end
end
