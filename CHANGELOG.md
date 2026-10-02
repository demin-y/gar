# Changelog

## [Не выпущено] — 2.0.0

Версия готовится к встраиванию в Rails-приложение; публичный API меняется несовместимо
с 1.x. Ход работ — `docs/rails_integration_plan.md`.

### Поиск для формы (этап 6)

**Несовместимые изменения**
- `path_type:` в методах `Gar::Search` переименован в `hierarchy:`; по умолчанию —
  `config.default_hierarchy` (`:adm`).
- Текстовый запрос разбирается гемом (нормализация и синонимы), а не `websearch_to_tsquery`:
  операторы `or`, `-слово` и кавычки больше не поддерживаются.
- В `AddressObject` и `House` добавлено поле `region_code`; к `Data`-результатам добавлены
  `as_json`/`to_json`.
- Схема: у `address_objects` вместо индекса по выражению — колонка `name_tsv` (`GENERATED`)
  с GIN, колонки `house_count` и `is_capital`; у таблиц параметров — частичный индекс
  почтового индекса. Нужен новый импорт.

**Новое**
- `region_codes:` и `within:` (GUID объекта: поиск в его поддереве по `path_ids`) у всех методов
  поиска (Т6); `region_code` в каждом результате (Т9).
- `Gar.autocomplete(query, region_codes:, within:, hierarchy:, limit:)` → `Gar::Suggestion`:
  улица и дом одной строкой, точный номер выше префиксного, дома выше улиц (Т7).
- `Gar.address(guid, hierarchy:)` → `Gar::Address`: субъект, район, город, улица, дом, корпус,
  строение, индекс, ОКАТО, ОКТМО, цепочка GUID родителей, строка по правилам ФНС и краткая (Т8).
- `Gar::Synonyms`: синонимы из справочников типов, встроенного словаря
  `lib/gar/data/synonyms.yml` и `config.synonyms`; `config.builtin_synonyms`.
- `Gar::HouseNumber.parse("12а к 2 стр 1")` — разбор номера дома.
- Ранжирование: точное совпадение, административный центр, число домов в поддереве.
- Поиск по почтовому индексу: шесть цифр в `search_address_objects` и `Gar.autocomplete`.

### Тестовые данные (этап 5)

**Несовместимые изменения**
- `Gar.available?` проверяет `gar_meta.status = 'ready'` в текущей схеме (было — наличие
  таблицы и полнотекстовых индексов путей): схема без `gar_meta` недоступна.
- Удалены `spec/fixtures/*.sql`, `.devcontainer/db-test.Dockerfile` и
  `examples/test_data_export.rb`; test-БД в docker-compose — чистый `postgres:17`.

**Новое**
- `Gar::TestSupport.load_fixtures(conn = nil, schema:)` (`require "gar/test_support"`, Т16):
  связный набор `Gar::TestSupport::Sample` (Киров с домами `10а`, `10/2`, корпусами и
  строениями, параметрами и закрытыми записями; Сыктывкар; Москва; цепочка из правил ФНС с
  их OBJECTID) загружается тем же импортом, что и архив, с `gar_meta` и путями. Схема
  заменяется одним переименованием и только если её создал `load_fixtures` или она пуста.
  GUID объекта набора — `Sample.guid(objectid)`.
- `Importer#import_full_base` принимает вместо пути объект с интерфейсом архива
  (`TestSupport::MemoryArchive`) и `parallel:` (по умолчанию `config.parallel_import`).
- `examples/benchmarks/generate_archive.rb` — синтетический архив заданного объёма,
  `examples/benchmarks/import_and_search.rb` — время импорта, путей и p50/p95 поиска.

**Исправлено**
- Параллельный импорт через `Importer.new(conn)` открывал соединения воркеров по
  `config.database_url`, а не к базе переданного соединения.

### Объём и данные (этап 4)

**Несовместимые изменения**
- Вместо таблицы `database_version` импорт пишет в схему `gar_meta`: версия и дата выгрузки,
  субъекты, загруженные таблицы, типы параметров, `keep_history`, `prune_hierarchy`, статус
  (`importing` → `imported` → `ready`), время импорта и построения путей, версия гема. Чтение —
  `Gar::Meta.read(conn, schema)`.
- Пути домов включают корпус и строение: «д. 14 к. 1 стр. 3» (было «д. 14»).
- По умолчанию из иерархий убираются строки незагруженных объектов (участки, помещения,
  машино-места при наборе `:minimal`); прежнее поведение — `config.prune_hierarchy = false`.
- Параметры: кроме закрытых изменением (`CHANGEIDEND` ≠ 0) отбрасываются и истёкшие к дате
  выгрузки (`ENDDATE`), если не включён `keep_history`.
- `PathBuilder#build` без адресных объектов или без иерархий бросает `Gar::ConfigurationError`
  (было — молча возвращал 0).
- `Gar::Search` по иерархии, которой нет в схеме, бросает `Gar::ConfigurationError` (было —
  пустой список или `PG::UndefinedTable`).

**Новое**
- `config.region_codes = %w[43 11]` — импорт только этих субъектов (Т5); коды проверяются и
  приводятся к именам папок (`1` → `"01"`). `import_full_base(region_codes:)` по умолчанию берёт
  их из настройки.
- Колонки путей `adm_path_ids`/`mun_path_ids` (`bigint[]`, GIN): OBJECTID объектов пути — для
  поиска в границах и пересборки поддерева.
- `PathBuilder#invalidate(object_ids)` очищает пути объектов и их потомков для пересборки
  следующим `build`.
- `houses.house_num_norm` — вычисляемый номер для сравнения («10 А» → «10а»).

### Работа внутри Rails-процесса (этап 3)

**Несовместимые изменения**
- Адрес базы — `ENV["GAR_DATABASE_URL"]` или `config.database_url`; `DATABASE_URL` больше не
  читается, значения по умолчанию нет. Без настройки — `Gar::ConfigurationError`.
- `Gar::Database` — модуль соединений: удалены `Database.connection` (одно соединение на
  процесс), `Database.new`, `#with_retry`, `#ensure_alive!`, `#reconnect!` и настройки
  `db_retry_max_attempts`, `db_retry_base_delay`.
- `Gar::Search`: без соединения берёт его из пула на время вызова; схема фиксируется при
  создании (`Search.new(conn = nil, schema:)`). Результаты — `Gar::AddressObject` и
  `Gar::House` (`Data`) вместо объектов `mini_sql`; OBJECTID — `gar_object_id` (`object_id` занят
  Ruby), у результатов всегда оба пути и нет `rank`. Удалён аргумент `path_type:` у
  `find_*_by_guid`; неизвестный `path_type` — `ArgumentError`; некорректный GUID — `nil`/`[]`.
- `find_address_objects` без `parent_guid` учитывает `level:` (по умолчанию — регионы).
- Зависимость `mini_sql` удалена, добавлена `connection_pool`.
- `Gar::Database.discard_inherited_connections` удалён: соединения, переданные в
  `Importer.new`/`PathBuilder.new`, гем берёт под свою защиту от fork (`Database.adopt`).

**Новое**
- Пул соединений поиска: `config.pool_size` (5), `config.pool_timeout` (5 с),
  `Gar.with_connection { |conn| … }`. Пул пересоздаётся, когда меняются его настройки или
  адрес базы.
- Таймауты: `config.connect_timeout` (2 с) для всех соединений,
  `config.search_statement_timeout` (1 с) только для поиска.
- `Gar::UnavailableError`: нет соединения, `statement_timeout`, ожидание пула. Оборванное
  соединение в пул не возвращается.
- Fork-safety: после `fork` соединения гема отбрасываются без `PQfinish` (хук
  `Process._fork`), пул создаётся заново.
- `Gar.available?` — база отвечает, текущая схема есть, пути построены (запрос только к
  каталогу: таблица и полнотекстовые индексы путей).
- Событие `search.gar` через `ActiveSupport::Notifications`, если он загружен.

**Исправлено**
- `find_address_objects(level: [5, 6])` падал на массиве (ошибка 19).
- Поиск адресных объектов делал три запроса (название, счётчик, путь) — теперь один, с общей
  пагинацией, и пути не сканируются, если совпадений по названию хватает; имя схемы в SQL
  экранируется.

### Пути, загрузчик, конфигурация (этап 2)

**Несовместимые изменения**
- `Gar::FullPathBuilder` заменён `Gar::PathBuilder.new(conn, schema:).build(batch_size:,
  on_progress:)`. Методы `update_*_paths` и `populate_*_paths` удалены: какие пути строить,
  решает состав схемы (загруженные `address_objects`, `houses` и иерархии). Колонки путей
  создаёт импорт, `ALTER TABLE` больше не нужен.
- `Downloader#download_full_base` и `#download_delta` принимают `on_progress:
  ->(done, total, stage)` (байты, `stage = :download`) вместо `show_progress:` и больше
  не печатают в `$stdout`. Сетевые ошибки после всех попыток — `Gar::DownloadError`;
  `version_info` для неизвестной версии — тоже `Gar::DownloadError`.
- Зависимость `httparty` удалена (загрузчик на `Net::HTTP`).
- `Gar::NullLogger` удалён: `config.logger = false` даёт `Logger.new(File::NULL)`.

**Новое**
- Архив качается в `<имя>.zip.part` и переименовывается только целиком; после обрыва
  загрузка продолжается запросом `Range`, в том числе при следующем запуске. Уже скачанный
  архив повторно не качается. Попытки (`api_retry_attempts`) считаются подряд без
  прогресса.
- Логгер выбирается при каждом обращении: `Rails.logger`, настроенный или заменённый после
  конфигурации гема, тоже подхватывается.
- `PathBuilder#build` возобновляем: заполняет только пустые пути; обе иерархии строятся за
  один проход по таблице, батч — один запрос. Полнотекстовые индексы — только по
  загруженным иерархиям, с `import_maintenance_work_mem`.

**Исправлено**
- В пути попадали неактуальные записи адресных объектов (`is_active` без `is_actual`): при
  импорте с историей названия дублировались.
- Путь дома без номера (`house_num IS NULL`) был пустым — теперь это путь улицы.
- README: удалены несуществующие `populate_full_paths`, `get_hierarchy`, `get_version_info`.

### Импорт (этап 1)

**Несовместимые изменения**
- Требуется Ruby ≥ 3.3; rubyzip 3.x.
- Таблицы описаны декларативно в `Gar::Schema` (все 28 файлов архива). Удалены
  `Gar::Entities`, `Gar::XmlParser`, `Gar::Xml::*`.
- Настройки `import_entities`, `entity_options` и `batch_size` удалены. Состав данных задают
  `config.preset` (`:minimal` по умолчанию, `:extended`, `:full`), `config.tables`,
  `config.hierarchies`, `config.param_types`, `config.keep_history` (список таблиц; `true` —
  все, где есть неактуальные записи). Справочники корня архива грузятся всегда.
- `parallel_import_workers` по умолчанию — число ядер, но не больше 4.
- По умолчанию загружаются только актуальные записи (`ISACTUAL=1`, действующие строки
  иерархий и параметров); `reestr_objects` в набор по умолчанию не входит.
- Таблица `params` заменена таблицами по файлам ФНС: `addr_obj_params`, `house_params`
  (и `stead_params`, `apartment_params`, `room_params`, `carplace_params` в наборах
  `:extended`/`:full`). Параметры фильтруются по типам при разборе.
- Колонки: `object_guid` и прочие GUID — тип `uuid`; строки — `text`; пустой или
  отсутствующий атрибут — `NULL` (а не `0`); у `houses` появились `add_num1`, `add_type1`,
  `add_num2`, `add_type2`; у `mun_hierarchy` — `oktmo` вместо кодов административной
  иерархии; у объектов и иерархий — `region_code` из имени папки архива. В `reestr_objects`
  колонки дат названы `create_date`, `update_date`.
- Версия архива берётся из `version.txt` внутри zip; без него — `Gar::ImportError`.
  `Importer#extract_version_from_archive` удалён.
- `Importer#create_schema`, `#drop_schema`, `#create_tables` больше не публичные; удалён
  `Importer#db` (обёртка `Gar::Database`).
- Ошибки импорта не глотаются: любая ошибка — `Gar::ImportError` (наследник `Gar::Error`).
  Иерархия ошибок — в `lib/gar/errors.rb`.

**Новое**
- `import_full_base(zip, schema:, region_codes:, on_progress:)`: своя целевая схема, только
  папки выбранных субъектов, колбэк прогресса `->(done, total, stage)` в байтах XML.
- XML читается потоком прямо из zip — распаковка на диск не нужна. Память воркера постоянна
  (~45 МБ вместе с Ruby) при любом размере файла; целостность файла проверяется по CRC32.
- Одна очередь файлов «таблица × субъект» для всех таблиц, крупные первыми; первичные ключи
  и индексы строятся после загрузки, по таблицам параллельно, затем `ANALYZE`. Индексы на
  `object_guid`.
- `config.import_maintenance_work_mem` — память PostgreSQL на построение индексов (по
  умолчанию не задаётся: действует настройка сервера).
- Гибель воркера (например, от нехватки памяти) — `Gar::ImportError` с подсказкой.
- `Gar.reset_configuration!`.

**Исправлено**
- Ключ `AS_PARAM` находил только `AS_PARAM_TYPES`: параметры не загружались.
- Подстрочный выбор файлов захватывал чужие таблицы (`AS_HOUSES` → `AS_HOUSES_PARAMS`).
- Обрезанный файл от прерванной распаковки молча брался повторно.
- Импорт той же версии удалял текущую схему, если она называлась `gar_v<версия>`.
- Дочерние процессы параллельного импорта закрывали унаследованное соединение родителя.
- Переключение схем идёт в одной транзакции. Если у текущей схемы нет сведений о версии,
  переключение больше не падает: резервная копия называется по времени.
