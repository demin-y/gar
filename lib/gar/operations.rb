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
    def switch(schema, on_progress: nil)
      with_operation_connection do |conn|
        on_progress&.call(0, 1, :switch)
        status = Meta.read(conn, schema)&.status
        raise ConfigurationError, "Схема #{schema} не готова (#{status || 'нет gar_meta'}): сначала Gar.build_paths" unless status == "ready"

        Importer.new(conn).switch_to_imported_schema(schema)
        on_progress&.call(1, 1, :switch)
        schema
      end
    end

    # Удаляет резервные схемы сверх keep_backups и схемы импорта, которые уже не станут
    # текущими: незавершённые и не новее текущей. Текущую не трогает. Возвращает удалённые
    def cleanup_schemas(keep_backups: configuration.keep_backups)
      with_operation_connection do |conn|
        Database.with_lock(conn, "Очистка схем") { Schemas.cleanup(conn, configuration.database_schema, keep_backups:) }
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
  end
end
