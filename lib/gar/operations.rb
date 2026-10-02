# frozen_string_literal: true

module Gar
  # Загрузка и обновление базы из приложения (Т12, Т13): шаги вызываются по отдельности, например
  # из фоновой задачи, и сообщают прогресс через on_progress: ->(done, total, stage) {}.
  #
  #   zip    = Gar.download(on_progress:)                      # stage :download — байты
  #   schema = Gar.import(zip, region_codes: %w[43 11], on_progress:) # :import — байты XML, :indexes — таблицы
  #   Gar.build_paths(schema, on_progress:)                    # :paths — записи
  #   Gar.switch(schema, on_progress:)                         # :switch
  #
  # Каждый шаг открывает своё соединение (без statement_timeout) и закрывает его. Повторный
  # вызов безопасен: скачанный архив не качается заново, загруженная схема не загружается,
  # заполненные пути не строятся. Изменяющие шаги держат advisory lock — второй процесс
  # получает LockedError. Ошибки — исключения гема (Gar::Error), без exit и вывода в консоль.
  class << self
    # Скачивает полную выгрузку версии version_id (по умолчанию последней) в
    # config.full_base_dir; возвращает путь к zip
    def download(version_id = nil, on_progress: nil)
      downloader = Downloader.new
      info       = version_id ? downloader.version_info(version_id) : downloader.latest_version
      downloader.download_full_base(info, on_progress:)
    end

    # Импортирует архив source (путь к zip, по умолчанию — последний в config.full_base_dir) в
    # схему <database_schema>_v<версия> и возвращает её имя. Если текущая схема уже загружена из
    # этой версии с теми же настройками и готова, возвращает текущую: импорт не нужен
    def import(source = nil, region_codes: nil, on_progress: nil)
      source ||= Importer.find_latest_full_base_zip or
        raise ConfigurationError, "Нет скачанного архива в #{configuration.full_base_dir}: сначала Gar.download"
      with_operation_connection { Importer.new(_1).import_full_base(source, region_codes:, on_progress:, reuse_current: true) }
    end

    # Строит пути схемы (по умолчанию текущей) — PathBuilder#build; возвращает число записей
    # с новыми путями
    def build_paths(schema = configuration.database_schema, on_progress: nil)
      with_operation_connection { PathBuilder.new(_1, schema:).build(on_progress:) }
    end

    # Делает schema текущей; прежняя текущая становится резервной, резервные сверх
    # config.keep_backups удаляются. Переключить можно только готовую схему (пути построены)
    def switch(schema, on_progress: nil) = with_operation_connection { switch_on(_1, schema, on_progress) }

    # Удаляет резервные схемы сверх keep_backups и схемы импорта, которые уже не станут
    # текущими: незавершённые и не новее текущей. Текущую не трогает. Возвращает удалённые
    def cleanup_schemas(keep_backups: configuration.keep_backups) = with_operation_connection { cleanup_on(_1, keep_backups) }

    # Обновляет базу до последней выгрузки ФНС — точка входа для крона. Если текущая схема
    # готова, а её версия есть в списке выгрузок, дельты новее неё применяются по порядку (не
    # больше config.max_delta_chain подряд, у каждой должен быть архив). Иначе — нет базы,
    # разрыв цепочки, слишком длинная цепочка — полный импорт последней выгрузки, пути,
    # переключение и очистка схем. Всё обновление держит блокировку базы: второй запуск получает
    # LockedError. on_progress — как у шагов загрузки, для дельт stage = :delta (байты XML).
    # Возвращает Gar::UpdateResult
    def update!(on_progress: nil)
      with_operation_connection do |conn|
        Database.with_lock(conn, "Обновление ГАР") do
          downloader = Downloader.new
          current    = Meta.read(conn, configuration.database_schema)
          versions   = downloader.all_versions.sort_by { _1["VersionId"] }
          latest     = versions.last or raise DownloadError, "API ФНС не вернул ни одной выгрузки"
          from       = current&.version_id
          next UpdateResult.new(kind: :none, from_version: from, to_version: from, versions: []) if current&.status == "ready" && from >= latest["VersionId"]

          if (chain = delta_chain(current, versions))
            chain.each { Delta.new(conn).apply(downloader.download_delta(_1, on_progress:), on_progress:) }
            UpdateResult.new(kind: :delta, from_version: from, to_version: chain.last["VersionId"], versions: chain.map { _1["VersionId"] })
          else
            full_update(conn, downloader.download_full_base(latest, on_progress:), on_progress)
            UpdateResult.new(kind: :full, from_version: from, to_version: latest["VersionId"], versions: [])
          end
        end
      end
    end

    # Версия и настройки текущей схемы (Gar::Meta: version_id, version_date, region_codes,
    # status, imported_at…) или nil, если её нет или она загружена не импортом гема
    def current_version = with_connection { Meta.read(_1, configuration.database_schema) }

    private

    def with_operation_connection
      conn = Database.create_connection
      yield conn
    ensure
      conn&.close
    end

    def switch_on(conn, schema, on_progress)
      on_progress&.call(0, 1, :switch)
      status = Meta.read(conn, schema)&.status
      raise ConfigurationError, "Схема #{schema} не готова (#{status || 'нет gar_meta'}): сначала Gar.build_paths" unless status == "ready"

      Importer.new(conn).switch_to_imported_schema(schema)
      on_progress&.call(1, 1, :switch)
      schema
    end

    def cleanup_on(conn, keep_backups)
      Database.with_lock(conn, "Очистка схем") { Schemas.cleanup(conn, configuration.database_schema, keep_backups:) }
    end

    # Выгрузки после текущей версии, если их можно накатить дельтами; nil — нужен полный импорт
    def delta_chain(current, versions)
      return no_chain("готовой текущей схемы нет") unless current&.status == "ready"

      index = versions.index { _1["VersionId"] == current.version_id } or return no_chain("версии #{current.version_id} нет в списке выгрузок ФНС")
      chain = versions.drop(index + 1)
      return no_chain("дельт после #{current.version_id}: #{chain.size}, больше max_delta_chain") if chain.size > configuration.max_delta_chain

      missing = chain.find { _1["GarXMLDeltaURL"].to_s.empty? }
      missing ? no_chain("у выгрузки #{missing['VersionId']} нет дельты") : chain
    end

    def no_chain(reason)
      logger.info "Полный импорт: #{reason}"
      nil
    end

    # Полный импорт архива zip в новую схему, пути, переключение и очистка схем
    def full_update(conn, zip, on_progress)
      schema = Importer.new(conn).import_full_base(zip, on_progress:, reuse_current: true)
      return if schema == configuration.database_schema # текущая уже загружена из этой выгрузки

      PathBuilder.new(conn, schema:).build(on_progress:)
      switch_on(conn, schema, on_progress)
      cleanup_on(conn, configuration.keep_backups)
    end
  end
end
