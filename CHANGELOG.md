# Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии — [SemVer](https://semver.org/lang/ru/).
Гем ставится из GitHub по тегу (`gem "gar", github: "demin-y/gar-ruby", tag: "v2.0.0"`), на
RubyGems не публикуется.

## [Не выпущено]

## [2.0.0] — 2026-10-17

Гем переписан для работы внутри Rails-приложения: загрузка нужных субъектов, обновление дельтами
по расписанию, поиск из потоков Puma. API несовместим с 1.0.0 — раздел «Переход с 1.0.0».

### Главное

- **Загрузка только нужных субъектов** (`config.region_codes`): из архива ФНС по HTTP Range
  качаются справочники и файлы этих субъектов — два субъекта ≈300 МБ вместо ≈50 ГБ; докачка после
  обрыва, повтор ответов 5xx и 429. XML читается потоком прямо из zip, без распаковки на диск.
- **Импорт** в новую схему рядом с текущей: таблицы — декларативно (`Gar::Schema`), набор данных —
  `config.preset` (`:minimal`, `:extended`, `:full`), только актуальные записи, файлы «таблица ×
  субъект» параллельно; сведения о схеме — `gar_meta`; переключение схем — одной транзакцией,
  резервные схемы и очистка (`Gar.switch`, `Gar.cleanup_schemas`).
- **Обновление по расписанию** — `Gar.update!`: дельты ФНС к текущей схеме или полный импорт (базы
  нет, изменились настройки, разрыв цепочки, раз в `full_import_interval` дней); блокировка базы
  от второго запуска, прогресс по стадиям и одной шкалой (`on_overall_progress`).
- **Поиск для формы адреса**: `Gar.autocomplete` — одна строка ввода («Киров, Ленина 10б»,
  «14к1с3»), дома и улицы одним списком с признаком точного номера; синонимы типов и сокращений;
  центр субъекта и его улицы — первыми.
- **Адрес по GUID** — `Gar.address` (и пачкой): разобранные поля с кратким и полным типом,
  номер дома без потерь, строки по правилам ФНС; `Gar.address_status` — почему адреса нет
  (снесён, упразднён, не найден).
- **Перенос старых адресов** — `Gar.match_house`: дом по GUID улицы и номеру (`:exact`, `:fuzzy`,
  `:none` с альтернативами); GUID улиц ФИАС = `OBJECTGUID` ГАР.
- **Работа внутри Rails**: пул соединений с таймаутами, `Gar::UnavailableError` для ручного
  ввода, безопасность после `fork`, Railtie (логгер приложения, rake-задачи `gar:*`, генератор
  `gar:install`), события `search.gar`, тестовый набор `Gar::TestSupport` для спек приложения.
- Проверено на реальных выгрузках ФНС (субъекты 43 и 11, 69 дельт подряд); цифры — README,
  «Объёмы» и «Скорость и качество».

### Переход с 1.0.0

Базу, загруженную 1.0.0, нужно загрузить заново: схема таблиц другая (`Gar.update!` без текущей
готовой схемы делает полный импорт).

- Ruby ≥ 3.3, rubyzip 3.x; зависимости `mini_sql` и `httparty` убраны, добавлена `connection_pool`.
- Адрес базы — `GAR_DATABASE_URL` или `config.database_url`; `DATABASE_URL` больше не читается.
- Убраны `Gar::Entities`, `Gar::XmlParser`, `Gar::FullPathBuilder` (→ `Gar::PathBuilder`),
  `Gar::NullLogger` (→ `config.logger = false`), настройки `import_entities`, `entity_options`,
  `batch_size`, `db_retry_*` (состав данных — `config.preset`, `tables`, `hierarchies`,
  `param_types`, `keep_history`).
- `Gar::Search`: результаты — `Gar::AddressObject` и `Gar::House` (`Data`, OBJECTID —
  `gar_object_id`), `path_type:` → `hierarchy:`, соединение — из пула на время вызова; запрос
  разбирает гем (операторы `websearch_to_tsquery` не поддерживаются).
- `Downloader`: `on_progress:` вместо `show_progress:`, в `$stdout` не печатает; сетевые ошибки —
  `Gar::DownloadError`. Ошибки гема — наследники `Gar::Error` (`lib/gar/errors.rb`).
- Схема: таблица `params` → `addr_obj_params`, `house_params`…; GUID — `uuid`; `database_version` →
  `gar_meta`; схемы импорта — `<database_schema>_v<версия>`, резервные —
  `<database_schema>_backup_v<версия>`.
- По умолчанию загружаются только актуальные записи (`config.keep_history` — с историей), а из
  иерархий убираются строки незагруженных объектов (`config.prune_hierarchy = false` — оставить).
- Пути домов включают корпус и строение («д. 14 к. 1 стр. 3»); `Gar.available?` проверяет
  `gar_meta.status = 'ready'` в текущей схеме.

## [1.0.0] — 2026-02-11

Первая версия (только в git, тег `v1.0.0`): скачивание полной выгрузки ГАР с сайта ФНС, разбор
XML и импорт в PostgreSQL, полнотекстовый и каскадный поиск, поиск по GUID, полные строки
адресов, административная и муниципальная иерархии.

[Не выпущено]: https://github.com/demin-y/gar-ruby/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/demin-y/gar-ruby/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/demin-y/gar-ruby/tree/v1.0.0
