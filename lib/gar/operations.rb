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
    # config.full_base_dir; возвращает путь к zip. С субъектами (по умолчанию
    # config.region_codes) — только их файлы загружаемых таблиц и справочники (сотни мегабайт
    # вместо ~50 ГБ, Downloader#download_full_base); пустой список — весь архив
    def download(version_id = nil, region_codes: configuration.region_codes, on_progress: nil)
      downloader = Downloader.new
      info       = version_id ? downloader.version_info(version_id) : downloader.latest_version
      downloader.download_full_base(info, region_codes:, on_progress:)
    end

    # Импортирует архив source (путь к zip, по умолчанию — последний в config.full_base_dir) в
    # схему <database_schema>_v<версия> и возвращает её имя. Если текущая схема уже загружена из
    # этой версии с теми же настройками и готова, возвращает текущую: импорт не нужен
    def import(source = nil, region_codes: nil, on_progress: nil)
      source ||= Importer.find_latest_full_base_zip(region_codes: region_codes || configuration.region_codes) or
        raise ConfigurationError, "Нет скачанного архива с нужными субъектами в #{configuration.full_base_dir}: сначала Gar.download"
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
    # текущими: незавершённые и старее текущей (схема той же версии ждёт переключения).
    # Текущую не трогает. Возвращает удалённые
    def cleanup_schemas(keep_backups: configuration.keep_backups) = with_operation_connection { cleanup_on(_1, keep_backups) }

    # Обновляет базу до последней выгрузки ФНС — точка входа для крона. Если текущая схема
    # готова, загружена с теми же настройками, что в config (субъекты, таблицы, типы параметров,
    # keep_history, prune_hierarchy), а её версия есть в списке выгрузок, дельты новее неё
    # применяются по порядку (не больше config.max_delta_chain подряд, у каждой должен быть
    # архив). Иначе — нет базы, настройки изменились (добавили субъект), разрыв цепочки,
    # слишком длинная цепочка — полный импорт последней выгрузки (с субъектами — частичная
    # загрузка, Gar.download), пути, переключение и очистка схем. Всё обновление держит
    # блокировку базы: второй запуск получает LockedError. on_progress — как у шагов загрузки,
    # для дельт stage = :delta (байты XML). После обновления удаляет ставшие ненужными архивы
    # (config.cleanup_downloads, Downloader#remove_outdated). Возвращает Gar::UpdateResult
    # (reason — почему полный импорт)
    def update!(on_progress: nil)
      with_operation_connection do |conn|
        Database.with_lock(conn, "Обновление ГАР") do
          downloader = Downloader.new
          versions   = downloader.all_versions.sort_by { _1["VersionId"] }
          raise DownloadError, "API ФНС не вернул ни одной выгрузки" if versions.empty?

          result = update_on(conn, downloader, Meta.read(conn, configuration.database_schema), versions, on_progress)
          downloader.remove_outdated(result.to_version) if configuration.cleanup_downloads && result.kind != :none
          result
        end
      end
    end

    # Версия и настройки текущей схемы (Gar::Meta: version_id, version_date, region_codes,
    # status, imported_at…) или nil, если её нет или она загружена не импортом гема
    def current_version = with_connection { Meta.read(_1, configuration.database_schema) }

    # Состояние базы — Gar::Status: текущая схема, её последние дельты (не больше updates),
    # резервные схемы и схемы импорта — с gar_meta и местом на диске. Хватает права SELECT
    def status(updates: 5)
      current = configuration.database_schema
      with_connection do |conn|
        backups = Schemas.backups(conn, current)
        imports = Schemas.imports(conn, current)
        sizes   = Schemas.sizes(conn, [current, *backups, *imports])
        info    = ->(name) { SchemaInfo.new(name:, meta: Meta.read(conn, name), size: sizes.fetch(name)) }
        Status.new(current: (info.call(current) if sizes.key?(current)), updates: Delta.history(conn, current, limit: updates),
                   backups: backups.map(&info), imports: imports.map(&info))
      end
    end

    private

    def with_operation_connection
      conn = Database.create_connection
      yield conn
    ensure
      conn&.close
    end

    def switch_on(conn, schema, on_progress)
      on_progress&.call(0, 1, :switch)
      meta = Meta.read(conn, schema)
      raise ConfigurationError, "Схема #{schema} не готова (#{meta&.status || 'нет gar_meta'}): сначала Gar.build_paths" unless meta&.ready?

      Importer.new(conn).switch_to_imported_schema(schema)
      on_progress&.call(1, 1, :switch)
      schema
    end

    def cleanup_on(conn, keep_backups)
      Database.with_lock(conn, "Очистка схем") { Schemas.cleanup(conn, configuration.database_schema, keep_backups:) }
    end

    # Обновление текущей схемы current до последней из versions (по возрастанию): полный импорт
    # или дельты — Gar::UpdateResult
    def update_on(conn, downloader, current, versions, on_progress)
      from = current&.version_id
      if (reason = full_import_reason(current, versions))
        logger.info "Полный импорт: #{reason}"
        latest = versions.last
        full_update(conn, downloader.download_full_base(latest, region_codes: configuration.region_codes, on_progress:), on_progress)
        return UpdateResult.new(kind: :full, from_version: from, to_version: latest["VersionId"], versions: [], reason:)
      end

      chain = versions.select { _1["VersionId"] > from }
      return UpdateResult.new(kind: :none, from_version: from, to_version: from, versions: []) if chain.empty?

      chain.each { Delta.new(conn).apply(downloader.download_delta(_1, on_progress:), on_progress:) }
      UpdateResult.new(kind: :delta, from_version: from, to_version: chain.last["VersionId"], versions: chain.map { _1["VersionId"] })
    end

    # Почему нужен полный импорт, а не дельты (versions — по возрастанию); nil — текущая схема
    # обновляется дельтами или уже последней версии. Причина есть — текущую схему загрузить
    # заново нельзя: её нет, она загружена иначе, старше последней версии или пора по расписанию
    def full_import_reason(current, versions)
      settings = Meta.settings(region_codes: configuration.region_codes, tables: configuration.import_tables.map(&:name))
      return "готовой текущей схемы нет" unless current&.ready?
      return "настройки загрузки в config (субъекты, таблицы…) не совпадают с текущей схемой" unless current.settings == settings
      return "прошлый полный импорт — #{current.imported_at.to_date}, больше full_import_interval дней назад" if full_import_due?(current)

      chain_break(current.version_id, versions) unless current.version_id >= versions.last["VersionId"]
    end

    # Почему выгрузки после version_id нельзя накатить дельтами; nil — можно
    def chain_break(version_id, versions)
      index = versions.index { _1["VersionId"] == version_id } or return "версии #{version_id} нет в списке выгрузок ФНС"
      chain = versions.drop(index + 1)
      return "дельт после #{version_id}: #{chain.size}, больше max_delta_chain" if chain.size > configuration.max_delta_chain

      missing = chain.find { _1["GarXMLDeltaURL"].to_s.empty? }
      "у выгрузки #{missing['VersionId']} нет дельты" if missing
    end

    # Прошлый полный импорт старее config.full_import_interval дней
    def full_import_due?(current)
      days = configuration.full_import_interval
      days && current.imported_at && current.imported_at < Time.now - (days * Downloader::SECONDS_PER_DAY)
    end

    # Полный импорт архива zip в новую схему (текущая не переиспользуется: см.
    # full_import_reason), пути, переключение и очистка схем
    def full_update(conn, zip, on_progress)
      schema = Importer.new(conn).import_full_base(zip, on_progress:)

      PathBuilder.new(conn, schema:).build(on_progress:)
      switch_on(conn, schema, on_progress)
      cleanup_on(conn, configuration.keep_backups)
    end
  end
end
