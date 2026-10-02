# frozen_string_literal: true

# Настройки гема gar (ГАР — Государственный адресный реестр). Значения по умолчанию указаны
# в комментариях; раскомментируйте то, что нужно изменить. Подробности — README гема.
Gar.configure do |config|
  # --- База -------------------------------------------------------------------------------
  # Подключение — переменная GAR_DATABASE_URL (не DATABASE_URL: это база приложения).
  # Поиску хватает пользователя с правом SELECT, импорту нужен пользователь с CREATE на базу.
  # config.database_url    = ENV.fetch("GAR_DATABASE_URL", nil)
  # config.database_schema = "gar"   # текущая схема; импорт — gar_v<версия>, резервные — gar_backup_v<версия>

  # Пул соединений поиска на процесс (Puma — по числу потоков); таймауты в секундах
  # config.pool_size                = ENV.fetch("RAILS_MAX_THREADS", 5).to_i
  # config.pool_timeout             = 5
  # config.connect_timeout          = 2
  # config.search_statement_timeout = 1

  # --- Состав данных ------------------------------------------------------------------------
  # Субъекты — папки архива; пустой список — вся страна
  # config.region_codes = %w[43 11]
  # Набор таблиц: :minimal (поиск и адресная строка), :extended (+ участки, помещения), :full
  # config.preset      = :minimal
  # config.hierarchies = [:adm, :mun]   # можно оставить одну иерархию
  # config.default_hierarchy = :adm     # иерархия поиска и адреса по умолчанию

  # --- Скачивание и обновление --------------------------------------------------------------
  # config.full_base_dir   = Rails.root.join("storage/gar/full_base").to_s
  # config.delta_dir       = Rails.root.join("storage/gar/delta").to_s
  # config.api_ssl_verify  = true   # у ФНС сертификат российского УЦ: добавьте его в хранилище ОС
  # config.keep_backups    = 1      # прежних текущих схем после переключения
  # config.max_delta_chain = 30     # больше дельт подряд — полный импорт вместо цепочки
  # config.parallel_import_workers = 4

  # --- Поиск --------------------------------------------------------------------------------
  # Свои синонимы поверх встроенного словаря и справочников типов ГАР
  # config.synonyms = { "проспект" => %w[пркт] }

  # --- Логи ---------------------------------------------------------------------------------
  # По умолчанию — Rails.logger; false — без логов
  # config.logger = Rails.logger
end
