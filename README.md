# GAR — Ruby-гем для Государственного адресного реестра

[![CI](https://github.com/demin-y/gar/actions/workflows/ci.yml/badge.svg)](https://github.com/demin-y/gar/actions/workflows/ci.yml)
[![Ruby](https://img.shields.io/badge/ruby-3.3+-red.svg)](https://www.ruby-lang.org/)
[![Gem Version](https://badge.fury.io/rb/gar.svg)](https://badge.fury.io/rb/gar)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Гем скачивает выгрузки ГАР (ФИАС) с сайта ФНС, загружает нужные субъекты в PostgreSQL,
обновляет базу дельтами и ищет по ней адреса вплоть до дома. Рассчитан на встраивание в
Rails-приложение: поиск работает из потоков Puma, загрузка и обновление — из фоновых задач.

## Возможности

- Загрузка только нужных субъектов потоком из zip, без распаковки (`config.region_codes`)
- Автодополнение одной строки ввода для формы адреса (`Gar.autocomplete`)
- Адрес по GUID с разобранными полями и строкой по правилам ФНС (`Gar.address`)
- Перенос старых адресов: дом по GUID улицы и номеру (`Gar.match_house`)
- Полнотекстовый и каскадный поиск, поиск по GUID (`Gar::Search`)
- Административная и муниципальная иерархии
- Обновление по расписанию: дельты ФНС к текущей схеме или полный импорт (`Gar.update!`)
- Rails: rake-задачи `gar:*`, генератор инициализатора, логгер приложения, события
  `ActiveSupport::Notifications`
- Тестовый набор данных для спек приложения (`Gar::TestSupport`)

## Установка

```ruby
# Gemfile
gem "gar"
```

```bash
bundle install
bin/rails g gar:install   # config/initializers/gar.rb со всеми настройками
```

## Требования

- Ruby 3.3+
- PostgreSQL 16+ (CI проверяет 16 и 18)
- Место на диске — см. «Объёмы»

## Объёмы

Полная выгрузка ФНС одна на всю страну: даже для двух субъектов скачивается весь архив.
Распаковывать его не нужно — XML читается потоком прямо из zip, файлы других субъектов не
открываются. Цифры — по выгрузке 2026.01.16 (`docs/gar_archive_structure.md`), набор данных
`:minimal` (по умолчанию).

| | Вся страна | Два субъекта (43, 11) |
|---|---:|---:|
| Архив (скачать) | 49,3 ГБ | 49,3 ГБ |
| Распаковка на диск | не нужна | не нужна |
| XML к разбору без параметров | ≈ 94 ГБ | ≈ 1,4 ГБ |
| XML к разбору с параметрами | ≈ 188 ГБ | 2,95 ГБ |
| Дельта (скачать) | 20–45 МБ | 20–45 МБ |
| База (схема `gar`) | замер — `docs/real_data_checklist.md` | замер — там же |

- **Диск под архив** нужен на время импорта; после него zip можно удалить
  (`Gar::Downloader#cleanup_old_files`). Дельты весят десятки мегабайт.
- **Диск под базу:** при полном импорте новая схема загружается рядом с текущей, а после
  переключения прежняя остаётся резервной (`config.keep_backups = 1`) — на пике это три копии
  схемы. Дельты меняют текущую схему на месте.
- `rake gar:status` (`Gar.status`) показывает место, которое занимает каждая схема.

## Rails

Генератор `bin/rails g gar:install` создаёт `config/initializers/gar.rb` со всеми настройками
в комментариях. Минимум для двух субъектов — переменная `GAR_DATABASE_URL` и
`config.region_codes = %w[43 11]`. Логгер гема по умолчанию — `Rails.logger` (берётся при
каждом обращении, поэтому замена логгера приложения подхватывается).

Rake-задачи (в zsh аргументы — в кавычках):

| Задача | Что делает |
|---|---|
| `gar:download[version_id]` | скачивает полную выгрузку (по умолчанию последнюю) в `config.full_base_dir` |
| `gar:import[43,11]` | загружает скачанный архив в новую схему `gar_v<версия>`; без аргументов — `config.region_codes` |
| `gar:build_paths[схема]` | строит пути схемы (по умолчанию текущей) — нужны поиску |
| `gar:switch[схема]` | делает готовую схему текущей |
| `gar:update` | обновляет базу до последней выгрузки: дельты или полный импорт — для крона |
| `gar:status` | версия, статус, субъекты и размер текущей, резервных и загружаемых схем, последние дельты |
| `gar:cleanup` | удаляет лишние резервные схемы и схемы импорта, которые уже не станут текущими |

Первая загрузка — `bin/rails gar:update` (базы нет — полный импорт) или по шагам:

```bash
bin/rails gar:download
bin/rails "gar:import[43,11]"          # => Загружена схема gar_v20260116
bin/rails "gar:build_paths[gar_v20260116]"
bin/rails "gar:switch[gar_v20260116]"
bin/rails gar:status
```

Задачи печатают итог и прогресс долгих шагов, логи гема идут в лог приложения. Пока задача
держит базу, вторая получает `Gar::LockedError`; `gar:update` в этом случае сообщает и
выходит без ошибки — удобно для крона. Без Rails задачи подключаются строкой
`load "gar/tasks/gar.rake"` в `Rakefile`.

**Обновление по расписанию** — `gar:update` из крона или задача Solid Queue
([examples/active_job_update.rb](examples/active_job_update.rb)):

```yaml
# config/recurring.yml
production:
  gar_update:
    command: "Gar::Tasks.new.update"   # или class: GarUpdateJob
    queue: gar
    schedule: every tuesday and friday at 6am
```

ФНС публикует выгрузки по вторникам и пятницам.

## Подключение к базе

База ГАР — отдельная база или отдельный кластер, адрес — `GAR_DATABASE_URL`. Гем **не читает
`DATABASE_URL`**: в Rails это база самого приложения. Без адреса первое обращение к базе
бросает `Gar::ConfigurationError`.

```ruby
Gar.configure do |config|
  config.database_url = ENV["GAR_DATABASE_URL"] # по умолчанию
  config.pool_size    = 5   # пул соединений поиска на процесс (по соединению на поток Puma)
  config.pool_timeout = 5   # ожидание свободного соединения, с
  config.connect_timeout          = 2 # с; у libpq не меньше 2
  config.search_statement_timeout = 1 # с, только для поиска; nil — без ограничения
end
```

**Соединения.** Поиск берёт соединение из пула на время вызова, поэтому `Gar::Search`
можно вызывать из нескольких потоков; свой запрос — `Gar.with_connection { |conn| … }`.
Загрузка, пути, переключение и дельты открывают свои соединения без `statement_timeout`. Если
база недоступна, истёк таймаут запроса или пул занят дольше `pool_timeout`, поиск бросает
`Gar::UnavailableError`: приложение может переключить форму на ручной ввод.
`Gar.available?` — быстрая проверка (база отвечает, в текущей схеме `gar_meta.status = ready`:
импорт завершён, пути построены); подходит и для health-эндпоинта, нужен только `SELECT`.

**Fork.** После `fork` (Puma в кластерном режиме, Solid Queue) дочерний процесс не трогает
соединения родителя: гем отбрасывает их без закрытия и открывает свои. На macOS `libpq`
с Kerberos падает в форкнутом процессе — добавьте `gssencmode=disable` в строку
подключения: `postgresql://…/gar_db?gssencmode=disable`.

**Пользователи базы.** Поиску достаточно чтения, загрузке нужны права на схемы. Удобно
завести двух пользователей: приложение (веб и поиск) работает под читателем, загрузка и
обновление (`gar:*`, фоновые задачи) — под импортёром со своим `GAR_DATABASE_URL`.

```sql
CREATE ROLE gar_importer LOGIN PASSWORD '…';
CREATE ROLE gar_reader   LOGIN PASSWORD '…';
-- Импортёр создаёт, переименовывает и удаляет схемы gar, gar_v<версия>, gar_backup_v<версия>
GRANT CONNECT, CREATE, TEMPORARY ON DATABASE gar_db TO gar_importer;
-- Читатель получает доступ ко всем будущим схемам и таблицам импортёра: схемы создаются
-- заново при каждом полном импорте, а переключение — переименование
GRANT CONNECT ON DATABASE gar_db TO gar_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE gar_importer GRANT USAGE ON SCHEMAS TO gar_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE gar_importer GRANT SELECT ON TABLES TO gar_reader;
```

Схемы, созданные до `ALTER DEFAULT PRIVILEGES`, открываются вручную:
`GRANT USAGE ON SCHEMA gar TO gar_reader; GRANT SELECT ON ALL TABLES IN SCHEMA gar TO gar_reader;`.
Под читателем работают `Gar.autocomplete`, `Gar.address`, `Gar.match_house`, `Gar::Search`,
`Gar.available?` и `Gar.current_version`; запись в базу ему не нужна.

**Инструментирование.** Если загружен ActiveSupport, каждый вызов поиска публикует событие
`search.gar` (`method`, `query`/`guid`, `schema`, `count`) — оно видно в логах и APM:

```ruby
ActiveSupport::Notifications.subscribe("search.gar") do |event|
  Rails.logger.info "ГАР #{event.payload[:method]}: #{event.duration.round(1)} мс, #{event.payload[:count]}"
end
```

## Использование

### Быстрый старт без Rails

```ruby
require "gar"

Gar.configure do |config|
  config.database_url = "postgresql://localhost/gar_db"
  config.region_codes = %w[43 11]
  # config.logger = false  # без логов; по умолчанию — Rails.logger (если есть) или $stdout
end

Gar.update! # базы нет — скачивание, импорт, пути, переключение; дальше — дельты

Gar.autocomplete("Киров, Ленина 10б").each { puts _1.address }
Gar.address(house_guid).full_address
```

Примеры скриптов — в [examples/](examples/).

### Загрузка из приложения

Шаги загрузки вызываются по отдельности, например из фоновой задачи, и сообщают прогресс через
`on_progress: ->(done, total, stage) {}`. Каждый шаг сам открывает соединение с базой (без
`statement_timeout`) и закрывает его; ошибки — исключения гема (`Gar::Error`).

```ruby
progress = ->(done, total, stage) { Rails.logger.info("#{stage}: #{done}/#{total}") }

zip    = Gar.download(on_progress: progress)                   # :download — байты; Gar.download(version_id)
schema = Gar.import(zip, region_codes: %w[43 11], on_progress: progress) # :import — байты XML, :indexes — таблицы
Gar.build_paths(schema, on_progress: progress)                 # :paths — записи
Gar.switch(schema, on_progress: progress)                      # :switch
Gar.cleanup_schemas                                            # => имена удалённых схем

Gar.current_version # => Gar::Meta текущей схемы (version_id, version_date, region_codes, status…) или nil
Gar.status          # => Gar::Status: current, updates (последние дельты), backups, imports — для пульта
```

- **Имена схем.** Импорт идёт в `<database_schema>_v<версия>` (`gar_v20260116`), прежняя
  текущая после `switch` становится резервной `<database_schema>_backup_v<версия>`. Резервных
  остаётся `config.keep_backups` (по умолчанию 1), лишние удаляются после переключения.
  `Gar.cleanup_schemas` удаляет лишние резервные и схемы импорта, которые уже не станут
  текущими (прерванные и не новее текущей); текущую не трогает.
- **Повторный запуск безопасен.** Скачанный архив не качается заново, схема, уже загруженная из
  той же версии с теми же настройками (субъекты, таблицы, типы параметров, `keep_history`,
  `prune_hierarchy`), не загружается повторно, а если она уже текущая и готова,
  `Gar.import` возвращает текущую. Пути достраиваются только пустые — прерванный шаг
  продолжается следующим вызовом.
- **Один процесс за раз.** Импорт, построение путей, переключение, очистка и дельты держат
  advisory lock PostgreSQL на `config.database_schema`, скачивание — блокировку файла `<zip>.lock`;
  второй процесс сразу получает `Gar::LockedError`.
- **Порядок.** `Gar.switch` переключает только готовую схему (статус `ready`, пути построены),
  `Gar.build_paths` отказывается строить пути схемы, импорт в которую не завершён.
- **Прогресс из потоков.** При параллельном импорте в потоках (`in_threads`) `on_progress`
  вызывается из потоков импорта — по одному, но не из потока задачи: обработчик, который пишет
  в базу приложения, берёт соединение сам (`connection_pool.with_connection`).
- **Обновление.** Пока новая схема загружается, поиск работает по текущей; переключение —
  переименование схем в одной транзакции. Регулярное обновление — `Gar.update!` (ниже).

Полный пример фоновой задачи с отчётом на пульте — [examples/active_job_import.rb](examples/active_job_import.rb).

### Обновление по расписанию (дельты)

ФНС публикует выгрузки несколько раз в неделю, к каждой — дельту: изменения после предыдущей
выгрузки. `Gar.update!` — точка входа для крона:

```ruby
result = Gar.update!(on_progress: progress) # :download — байты, :delta — байты XML дельты
result.kind       # :none — уже последняя версия, :delta — применены дельты, :full — полный импорт
result.versions   # применённые дельты: [20260120, 20260123]
result.to_version # версия базы после обновления
```

- **Дельты.** Если текущая схема готова, а её версия есть в списке выгрузок ФНС, скачиваются и
  применяются по порядку все дельты новее неё. Иначе — базы нет, цепочка прервана (версии нет
  в списке, у выгрузки нет дельты), дельт больше `config.max_delta_chain` (по умолчанию 30) —
  полный импорт последней выгрузки, пути, переключение и очистка схем.
- **Применение.** Дельта меняет текущую схему в одной транзакции: читатели видят базу до или
  после неё. Записи сливаются по первичному ключу с фильтрами схемы из `gar_meta` (субъекты,
  актуальность, типы параметров, `prune_hierarchy`): прошедшая — добавляется или обновляется,
  не прошедшая (закрытая запись, недействующая строка иерархии, закрытый параметр) — удаляется.
  У затронутых объектов и их потомков пересобираются пути, у их предков — число домов и признак
  центра. Версия в `gar_meta` и журнал `gar_updates` (версия, время, число записей) обновляются в
  той же транзакции.
- **Повтор и сбой.** Дельта не новее текущей версии пропускается; упавшая откатывается целиком,
  а уже применённые дельты цепочки остаются — следующий запуск продолжит с места остановки.
  Всё обновление держит блокировку базы: второй запуск получает `Gar::LockedError`.
- Дельту можно применить и вручную: `Gar::Delta.new.apply(zip)` (к текущей схеме, по порядку
  версий — пропуск промежуточной дельты этот метод не замечает).

Из крона — `bin/rails gar:update`; пример задачи и расписания Solid Queue
(`config/recurring.yml`) — [examples/active_job_update.rb](examples/active_job_update.rb).

### 1. Загрузка данных (Downloader)

```ruby
downloader = Gar::Downloader.new

# Получение информации о последней версии
latest = downloader.latest_version
puts "Версия: #{latest['VersionId']}"
puts "Дата: #{latest['Date']}"

# Получение списка всех версий
versions = downloader.all_versions
versions.each do |v|
  puts "#{v['VersionId']} - #{v['TextVersion']}"
end

# Получение информации о конкретной версии по ID
version_info = downloader.version_info(20241201)

# Скачивание полной базы; on_progress получает скачанные и полные байты (total — nil,
# если сервер не сообщил размер)
zip_path = downloader.download_full_base(latest, on_progress: ->(done, total, _stage) { print "\r#{done}/#{total}" })
# => "./downloads/full_base/gar_xml_v20241201.zip"
```

Архив качается в `<имя>.zip.part` и переименовывается, только когда скачан целиком: импорт не
возьмёт недокачанный файл. После обрыва связи загрузка продолжается с места остановки (запрос
`Range`), в том числе при следующем запуске. Уже скачанный архив повторно не качается. Ошибки
сети и сервера — `Gar::DownloadError`.
```

**Настройка загрузчика:**

```ruby
Gar.configure do |config|
  # Директория для сохранения файлов
  config.full_base_dir = "./my_downloads"

  # Отключение SSL верификации (при проблемах с сертификатами)
  config.api_ssl_verify = false

  # Попыток подряд без прогресса при сетевых ошибках и пауза между ними, таймаут чтения
  config.api_retry_attempts = 3
  config.api_retry_timeout  = 5
  config.api_read_timeout   = 30
end
```

### 2. Импорт данных (Importer)

```ruby
importer = Gar::Importer.new

# Автоматический поиск последнего скачанного ZIP
zip_path = Gar::Importer.find_latest_full_base_zip

# Импорт с созданием версионированной схемы
# Схема будет названа gar_v20241201 (дата из архива)
schema_name = importer.import_full_base(zip_path)

# Переключение на новую схему: старая становится резервной gar_backup_v<версия>,
# резервные сверх config.keep_backups (по умолчанию 1) удаляются
importer.switch_to_imported_schema(schema_name)
```

**Настройка импорта:**

```ruby
Gar.configure do |config|
  # Параллельный импорт: одна очередь файлов «таблица × субъект», крупные первыми
  config.parallel_import = true
  config.parallel_import_workers = 8

  # Состав данных: :minimal (по умолчанию) — то, что нужно поиску и адресной строке;
  # :extended — плюс участки, помещения, реестр GUID и прежние названия улиц; :full — весь архив.
  # Справочники корня архива грузятся всегда.
  config.preset = :minimal

  # Субъекты — папки архива; пустой список (по умолчанию) — вся страна
  config.region_codes = %w[43 11]   # можно и числами: [43, 11]

  # Тонкая настройка поверх набора
  config.tables += [:steads]        # добавить таблицы субъекта
  config.hierarchies = [:adm]       # только административная иерархия
  config.param_types = [5, 6, 7]    # типы параметров: почтовый индекс, ОКАТО, ОКТМО
  config.keep_history = true        # хранить неактуальные записи
  config.prune_hierarchy = false    # не убирать из иерархий строки незагруженных объектов
end

# Субъекты можно передать и при вызове
importer.import_full_base(zip_path, region_codes: ["43"])
```

Минимальная настройка для двух субъектов — `GAR_DATABASE_URL` и `config.region_codes = %w[43 11]`.
Из архива читаются только корневые справочники и папки этих субъектов, остальные файлы не
открываются. Сколько времени и места займёт такой импорт, станет известно после прогона на
реальном архиве.

XML читается потоком прямо из zip: распаковка на диск не нужна, целостность каждого файла
проверяется по CRC32 из оглавления. Версия берётся из `version.txt` внутри архива. Первичные
ключи и индексы строятся после загрузки данных, по таблицам параллельно.

Что загружается из файлов субъекта:
- без `keep_history` — только актуальные записи; параметры — только действующие (не закрытые
  изменением и не истёкшие к дате выгрузки) и только типов `config.param_types`;
- иерархии содержат строки всех объектов субъекта, включая участки, помещения и машино-места.
  С `prune_hierarchy` (по умолчанию) после загрузки в них остаются только объекты загруженных
  таблиц: для набора `:minimal` — адресные объекты и дома.

**Сведения о схеме — `gar_meta`.** Импорт записывает в схему таблицу `gar_meta` (одна строка):
версию и дату выгрузки, субъекты, загруженные таблицы, типы параметров, `keep_history`,
`prune_hierarchy`, версию гема и статус — `importing` (идёт или прерван), `imported` (данные
и индексы готовы), `ready` (построены пути). Прочитать — `Gar::Meta.read(conn, schema)`.

**Память.** Воркер импорта занимает около 45 МБ (из них ~40 МБ — сам Ruby с гемами) и не
растёт с размером файла: даже файл на 4,8 ГБ читается кусками по 64 КБ. На Linux воркеры —
процессы, форкнутые от запустившего импорт процесса, поэтому запускайте импорт отдельной
задачей (rake, фоновый воркер), а не в процессе веб-сервера. На сервере с малым объёмом памяти:

```ruby
Gar.configure do |config|
  config.parallel_import_workers = 2   # по умолчанию — число ядер, но не больше 4
  # config.parallel_import = false     # совсем без воркеров: медленнее, минимум памяти
  # Память PostgreSQL на построение индексов: до этого объёма на каждый воркер.
  # По умолчанию не задаётся — действует настройка сервера.
  # config.import_maintenance_work_mem = "256MB"
end
```

### 3. Построение полных адресных путей

**Важно:** Этот шаг обязателен для работы полнотекстового поиска! Методы `search_address_objects` и `search_houses` используют колонки `full_adm_path` и `full_mun_path`.

```ruby
builder = Gar::PathBuilder.new(schema: "gar_v20260116") # по умолчанию — config.database_schema
builder.build(batch_size: 25_000, on_progress: ->(done, total, _stage) { puts "#{done}/#{total}" })
```

`build` заполняет у `address_objects` и `houses`:
- `full_adm_path`/`full_mun_path` — «Кировская обл, Киров г, Ленина ул, д. 14 к. 1 стр. 3» —
  и их `tsvector` с полнотекстовыми индексами;
- `adm_path_ids`/`mun_path_ids` — OBJECTID всех объектов пути от корня до самого объекта
  (`bigint[]` с GIN-индексом): `WHERE adm_path_ids @> ARRAY[<OBJECTID города>]` — всё внутри
  города.

Какие пути строить, решает состав схемы: путь по иерархии строится, только если она загружена
(`config.hierarchies`); без адресных объектов или без иерархий — `Gar::ConfigurationError`.
Путь собирается из действующих актуальных адресных объектов; дом без номера получает путь своей
улицы. В конце `build` переводит `gar_meta` в статус `ready`.

Заполняются только пустые пути, обе иерархии за один проход, батчами по возрастанию `id`:
прерванное построение продолжается повторным `build`. Чтобы пересобрать пути объекта и всего его
поддерева (после переименования или переноса), очистите их и запустите `build` снова:

```ruby
builder.invalidate([street_object_id]) # улица и все её дома
builder.build
```

**Примечание:** Процесс построения путей может занять несколько часов на полной базе. Каскадный поиск (`find_address_objects`, `find_houses`) и `Gar.address` работают без построения путей; `within:` и полнотекстовый поиск — только после него. В конце построения пересчитываются число домов в поддереве и признак административного центра адресных объектов (для ранжирования).

### 4. Поиск адресов (Search)

**Автодополнение одной строки ввода** (поле формы с Tom Select и т. п.):

```ruby
Gar.autocomplete("Киров, Ленина 10б", region_codes: %w[43 11], limit: 10)
# => [#<data Gar::Suggestion kind=:house, object_guid="…", gar_object_id=…, level=10, region_code="43",
#       name="д. 10б", address="Кировская обл, Киров г, Ленина ул, д. 10б">,
#     …, #<data Gar::Suggestion kind=:address_object, name="Ленина ул", …>]
Gar.autocomplete("Ленина 12 к2", within: kirov_guid) # только в поддереве города
```

Строка делится на текст и номер дома (`Gar::HouseNumber`: «10», «10а», «10/2», «12 к2»,
«14 корп. 1 стр. 3»). Без номера — адресные объекты по тексту, последнее слово — префикс.
С номером — дома на подходящих улицах: сначала точный номер (без корпуса и строения, если
их не ввели), затем номера, которые начинаются с введённого, после них — сами улицы. Шесть
цифр — почтовый индекс. Элементы — `Data` с `to_h`/`as_json`/`to_json`: их можно отдать в
JSON как есть.

**Адрес по GUID** — разобранные поля и строка по правилам ФНС
(`docs/Правила_формирования_адресной_строки.docx`):

```ruby
address = Gar.address(house_guid, hierarchy: :mun)
address.full_address  # => "Московская область, городской округ Павлово-Посадский, город Павловский Посад, улица Тихонова, дом 93"
address.short_address # => "Московская область, г.о. Павлово-Посадский, г Павловский Посад, ул Тихонова, д. 93"
address.to_h
# => { object_guid:, gar_object_id:, level:, hierarchy:, region_code: "50", region: "Московская область",
#      district: "городской округ Павлово-Посадский", city: "город Павловский Посад", street: "улица Тихонова",
#      house: "93", building: nil, structure: nil, postal_code:, okato:, oktmo:, parent_guids: [...], … }
```

Полное наименование элемента — тип и название («улица Ленина», тип из справочника по
краткому имени и уровню); у субъекта, муниципального района и поселения — действующее
официальное наименование. Индекс, ОКАТО и ОКТМО — параметры объекта, индекс при его
отсутствии — у ближайшего предка (улицы). `nil` — нет действующего объекта с таким GUID.

**Методы `Gar::Search`:**

```ruby
search = Gar::Search.new

search.search_address_objects("просп. Октябрьский", region_codes: ["43"], limit: 10)
search.search_address_objects("Кир", autocomplete: true)  # последнее слово — префикс
search.search_address_objects("610000")                   # почтовый индекс
search.search_houses("Ленина 10", within: city_guid)

regions = search.find_address_objects(level: 1)
cities  = search.find_address_objects(parent_guid: region_guid, level: [5, 6])
streets = search.find_address_objects(level: 8, within: city_guid)
houses  = search.find_houses(street_guid, limit: 50)

search.find_address_object_by_guid(guid)
search.find_address_objects_by_guids(guids) # => { guid => AddressObject }, одним запросом
search.find_house_by_guid(guid)
```

Результаты — `Gar::AddressObject` и `Gar::House` (`Data`): `id`, `gar_object_id` (OBJECTID
ГАР), `object_guid`, название или номер и тип, `region_code`, `full_adm_path`, `full_mun_path`;
у адресного объекта ещё `level` и `active` (недействующие объекты отдаёт только
`find_address_objects_by_guids`). Схема — `config.database_schema` или
`Gar::Search.new(schema: …)`.

Общие параметры всех методов поиска и `Gar.autocomplete`:
- `hierarchy:` — `:adm` или `:mun`, по умолчанию `config.default_hierarchy` (`:adm`). Если
  иерархия не загружена в схему (`config.hierarchies` при импорте), поиск по ней бросает
  `Gar::ConfigurationError`, а не отвечает пустым списком;
- `region_codes:` — только объекты этих субъектов (`%w[43 11]`);
- `within:` — GUID субъекта, района или города: только его поддерево по иерархии запроса.

**Перенос старых адресов.** GUID улицы ФИАС (`AOGUID`) в ГАР сохранён как `OBJECTGUID`
объекта — по описанию формата ФНС. Проверить это на своих данных:

```bash
GAR_DATABASE_URL=postgresql://… ruby examples/verify_fias_guids.rb streets.csv > report.tsv
```

Вход — файл, где в каждой строке GUID улицы и её старое название (разделитель любой); отчёт —
TSV с итогом по каждому GUID: «совпадает», «другое название» (переименование или чужой GUID),
«недействует», «не найден», сводка — в stderr. Пакетом GUID ищет
`search.find_address_objects_by_guids` (одним запросом на пачку).

Дом из старой записи — по GUID улицы и номеру:

```ruby
Gar.match_house(street_guid:, number: "12", building: "2")
# => #<data Gar::HouseMatch status=:exact, house=#<data Gar::House house_num="12", …>, alternatives=[…]>
Gar.match_house(street_guid:, number: "12 корп. 2")  # то же
Gar.match_house(street_guid:, number: "10", letter: "А")
```

Номер записи и номера домов приводятся к одному виду: регистр, пробелы, латинские буквы вместо
похожих русских, литера (`letter:` или дополнительный тип «литера») — часть номера, корпус и
строение — из `building:`/`structure:` или из самого номера («12к2»). Статус:
- `:exact` — совпали номер, корпус и строение;
- `:fuzzy` — с тем же номером ровно один дом, у которого есть всё записанное и что-то сверх
  него (записано «14», в ГАР — «14 к. 1 стр. 3»);
- `:none` — иначе, в том числе если подходят несколько домов («12» при «12 к. 2» и
  «12 стр. 1»): случайный дом не выбирается.

`alternatives` — другие действующие дома улицы с тем же числом в номере (для «10» — «10а»,
«10/2»): их можно показать оператору для ручного выбора.

**Текстовый запрос.** Регистр, `ё`, точки и знаки препинания не важны. Каждое слово ищется
вместе с синонимами (`Gar::Synonyms`), поэтому «просп. Октябрьский» находит «Октябрьский
пр-кт», а «Б. Садовая» — «Большая Садовая ул». Источники синонимов:
- справочники типов ГАР в схеме: «ул» ↔ «улица», «к.» ↔ «корпус»;
- встроенный словарь `lib/gar/data/synonyms.yml`: «просп», «мкрн», «б» → «большая»/«бульвар»,
  «им» → «имени» и др.; отключается `config.builtin_synonyms = false`;
- свои группы приложения — работают без перестроения индексов:

```ruby
Gar.configure { |config| config.synonyms = { "проспект" => %w[прсп], "имени" => %w[им.] } }
```

Порядок результатов: точное совпадение названия, административный центр (параметры 22/23),
число домов в поддереве (считает `PathBuilder`) — «Кир» выдаёт г. Киров раньше «Кировской
обл.» и посёлка «Кировский».

**Скорость.** Замер `examples/benchmarks/import_and_search.rb` на синтетике
(`generate_archive.rb`): 2 субъекта по 300 000 домов, PostgreSQL 16, 200 запросов каждого вида.

| Запрос | p50 | p95 |
|---|---:|---:|
| `Gar.autocomplete`: начало названия улицы | 3,3 мс | 11,4 мс |
| `Gar.autocomplete`: улица и номер дома | 5,3 мс | 7,2 мс |
| `Gar.autocomplete`: улица и номер в границах города | 3,0 мс | 3,9 мс |
| `Gar.address` по GUID дома | 1,7 мс | 2,2 мс |
| `search_address_objects`, автодополнение | 6,5 мс | 17,1 мс |
| `search_houses` «улица номер» | 7,1 мс | 13,7 мс |

Импорт архива — 10 с, построение путей с подсчётом рангов — 77 с.

### 5. Тестовые данные для спек приложения (TestSupport)

```ruby
# spec/rails_helper.rb
require "gar/test_support"

RSpec.configure do |config|
  config.before(:suite) { Gar::TestSupport.load_fixtures } # схема config.database_schema
end

# в спеке: GUID объекта набора — по его OBJECTID
Gar::TestSupport::Sample.guid(4_300_106) # дом «Ленина 14 к. 1 стр. 3» в Кирове
```

`load_fixtures(conn = nil, schema:)` загружает небольшой связный набор
(`Gar::TestSupport::Sample`) так же, как импорт реального архива: таблицы, субъекты и
иерархии — по текущим настройкам (`preset`, `region_codes`, `hierarchies`), затем индексы,
`gar_meta` и полные пути. В наборе:

- Кировская обл. (43): г. Киров, улицы и дома `12`, `10а`, `10/2`, с корпусом, строением,
  корпусом и строением; параметры (индекс, ОКТМО, официальное наименование), закрытые записи;
- улица и дом Сыктывкара (11) и Москвы (77);
- цепочка из правил ФНС (50): Московская обл., Павлово-Посадский г.о., г. Павловский Посад,
  ул. Тихонова, д. 93, кв. 17, ком. 2 — с OBJECTID из правил.

Набор собирается во временной схеме и заменяет `schema` одним переименованием. Заменить
можно только схему, созданную `load_fixtures`, или пустую: схему с другими данными метод не
трогает и бросает `Gar::ConfigurationError`. Без `conn` открывает соединение по
`config.database_url` и закрывает его.

## Схема базы данных

Гем создаёт в схеме по таблице на каждый файл архива ГАР (описание — `Gar::Schema`).
Набор `:minimal` по умолчанию:

- `address_objects` — адресные объекты (регионы, города, улицы)
- `houses` — здания и сооружения, с дополнительными номерами (корпус, строение) и
  `house_num_norm` — номером для сравнения («10 А» → «10а»)
- `adm_hierarchy`, `mun_hierarchy` — административная и муниципальная иерархии
- `addr_obj_params`, `house_params` — параметры объектов и домов (индекс, ОКАТО, ОКТМО…)
- справочники: `object_levels`, `address_object_types`, `house_types`, `add_house_types`,
  `param_types`, `operation_types`, `apartment_types`, `room_types`, `normative_docs_kinds`,
  `normative_docs_types`

У объектов и иерархий есть колонка `region_code` — код субъекта из имени папки архива.
Служебные таблицы: `gar_meta` — версия и настройки загрузки схемы, `gar_updates` — журнал
применённых дельт (`Gar::Delta.history(conn, schema)`).

## Источники данных

- Список выгрузок — API ФНС `https://fias.nalog.ru/WebServices/Public/GetAllDownloadFileInfo`
  (`config.api_all_versions_url`): у каждой выгрузки ссылки `GarXMLFullURL` и `GarXMLDeltaURL`.
- Архивы — файловый сервер `https://fias-file.nalog.ru/downloads/<ГГГГ.ММ.ДД>/`.
- У ФНС сертификат российского УЦ: добавьте его в хранилище сертификатов ОС или (только для
  проверки) `config.api_ssl_verify = false`.
- Из некоторых сетей API отвечает с таймаутом, хотя файловый сервер доступен; адрес API
  настраивается. Структура реальных архивов и дельт — `docs/gar_archive_structure.md`,
  оглавление архива без скачивания — `examples/tools/gar_toc.py`, `gar_delta_probe.py`.

## Разработка

```bash
bin/setup_test_db                 # тестовый PostgreSQL на :6433 (без Docker)
bundle exec rspec                 # все тесты; :slow — с GAR_SLOW_TESTS=1
bundle exec rubocop
```

DevContainer, Docker Compose и команды `make` — в [DEVELOPMENT.md](DEVELOPMENT.md). CI
(GitHub Actions) проверяет RuboCop и RSpec на Ruby 3.3, 3.4 и 4.0 с PostgreSQL 18 и на
Ruby 3.4 с PostgreSQL 16. Изменения версий — [CHANGELOG.md](CHANGELOG.md).

## Лицензия

Гем доступен как открытый исходный код на условиях [MIT License](https://opensource.org/licenses/MIT).

## Отказ от ответственности

Гем не связан с Федеральной налоговой службой России или каким-либо государственным органом.
Данные ГАР предоставляются публично и «как есть».
