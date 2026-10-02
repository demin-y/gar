# Changelog

## [Не выпущено] — 2.0.0

Версия готовится к встраиванию в Rails-приложение; публичный API меняется несовместимо
с 1.x. Ход работ — `docs/rails_integration_plan.md`.

### Импорт (этап 1)

**Несовместимые изменения**
- Требуется Ruby ≥ 3.3; rubyzip 3.x.
- Таблицы описаны декларативно в `Gar::Schema` (все 28 файлов архива). Удалены
  `Gar::Entities`, `Gar::XmlParser`, `Gar::Xml::*`.
- Настройки `import_entities`, `entity_options` и `batch_size` удалены. Состав данных задают
  `config.preset` (`:minimal` по умолчанию, `:extended`, `:full`), `config.tables`,
  `config.hierarchies`, `config.param_types`, `config.keep_history`. Справочники корня
  архива грузятся всегда.
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
- XML читается потоком прямо из zip — распаковка на диск не нужна.
- Одна очередь файлов «таблица × субъект» для всех таблиц, крупные первыми; первичные ключи
  и индексы строятся после загрузки, затем `ANALYZE`. Индексы на `object_guid`.
- `config.import_maintenance_work_mem` (по умолчанию `256MB`) для построения индексов.
- `Gar.reset_configuration!`.

**Исправлено**
- Ключ `AS_PARAM` находил только `AS_PARAM_TYPES`: параметры не загружались.
- Подстрочный выбор файлов захватывал чужие таблицы (`AS_HOUSES` → `AS_HOUSES_PARAMS`).
- Обрезанный файл от прерванной распаковки молча брался повторно.
- Импорт той же версии удалял текущую схему, если она называлась `gar_v<версия>`.
- Дочерние процессы параллельного импорта закрывали унаследованное соединение родителя.
- Переключение схем идёт в одной транзакции. Если у текущей схемы нет `database_version`,
  переключение больше не падает: резервная копия называется по времени.
