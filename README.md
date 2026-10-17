# GAR — Ruby-гем для Государственного адресного реестра

[![CI](https://github.com/demin-y/gar-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/demin-y/gar-ruby/actions/workflows/ci.yml)
[![Ruby](https://img.shields.io/badge/ruby-3.3+-red.svg)](https://www.ruby-lang.org/)
[![Version](https://img.shields.io/github/v/tag/demin-y/gar-ruby?label=version)](https://github.com/demin-y/gar-ruby/tags)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Гем скачивает выгрузки ГАР (ФИАС) с сайта ФНС, загружает нужные субъекты в PostgreSQL,
обновляет базу дельтами и ищет по ней адреса вплоть до дома. Рассчитан на встраивание в
Rails-приложение: поиск работает из потоков Puma, загрузка и обновление — из фоновых задач.

## Возможности

- Загрузка только нужных субъектов (`config.region_codes`): по HTTP Range качаются только их
  файлы (два субъекта — ~300 МБ вместо 50 ГБ), XML читается потоком без распаковки
- Автодополнение одной строки ввода для формы адреса (`Gar.autocomplete`)
- Адрес по GUID с разобранными полями и строкой по правилам ФНС (`Gar.address`)
- Перенос старых адресов: дом по GUID улицы и номеру (`Gar.match_house`)
- Полнотекстовый и каскадный поиск, поиск по GUID (`Gar::Search`)
- Административная и муниципальная иерархии
- Обновление по расписанию: дельты ФНС и периодический полный импорт (`Gar.update!`)
- Rails: rake-задачи `gar:*`, генератор инициализатора, логгер приложения, события
  `ActiveSupport::Notifications`
- Тестовый набор данных для спек приложения (`Gar::TestSupport`)

## Установка

Гем ставится из GitHub по тегу версии (на RubyGems не публикуется), в образе сборки нужен `git`:

```ruby
# Gemfile
gem "gar", github: "demin-y/gar-ruby", tag: "v2.0.0"
```

```bash
bundle install
bin/rails g gar:install   # config/initializers/gar.rb со всеми настройками
```

Требования: Ruby 3.3+, PostgreSQL 16+.

## Объёмы

Набор данных `:minimal` (по умолчанию), PostgreSQL 18, выгрузки ФНС 2026 года:

| | Вся страна | Два субъекта (43, 11) |
|---|---:|---:|
| Скачать | 49,3 ГБ | ≈ 300 МБ (1,5–2 мин) |
| XML к разбору (без распаковки на диск) | ≈ 188 ГБ | 2,7 ГБ |
| Импорт и пути | часы | ≈ 1,5–2 мин |
| База (схема `gar`) | — | 1,1 ГБ |
| Дельта: скачать / применить | 20–45 МБ | 20–45 МБ / медиана 0,9 с |

- Архив нужен только на время импорта: `Gar.update!` сам удаляет ненужные.
- При полном импорте новая схема загружается рядом с текущей, прежняя остаётся резервной
  (`config.keep_backups = 1`) — на пике три копии схемы. Дельты раздувают схему (за полгода —
  примерно в полтора раза), полный импорт по расписанию возвращает размер.
- Место каждой схемы — `rake gar:status` (`Gar.status`).

## Rails

Генератор `bin/rails g gar:install` создаёт `config/initializers/gar.rb` со всеми настройками в
комментариях. Минимум — переменная `GAR_DATABASE_URL` и `config.region_codes = %w[43 11]`.
Логгер по умолчанию — `Rails.logger`.

| Задача | Что делает |
|---|---|
| `gar:download[version_id]` | скачивает выгрузку (по умолчанию последнюю): с `config.region_codes` — только файлы этих субъектов |
| `gar:import[43,11]` | загружает скачанный архив в новую схему `gar_v<версия>`; без аргументов — `config.region_codes` |
| `gar:build_paths[схема]` | строит пути схемы (по умолчанию текущей) — нужны поиску |
| `gar:switch[схема]` | делает готовую схему текущей |
| `gar:update` | обновляет базу до последней выгрузки: дельты или полный импорт — для крона |
| `gar:status` | версия, субъекты и размер текущей, резервных и загружаемых схем, последние дельты |
| `gar:cleanup` | удаляет лишние резервные схемы и схемы импорта, которые уже не станут текущими |

Первая загрузка — `bin/rails gar:update` (базы нет — полный импорт) или по шагам (в zsh
аргументы — в кавычках):

```bash
bin/rails gar:download
bin/rails "gar:import[43,11]"          # => Загружена схема gar_v20260116
bin/rails "gar:build_paths[gar_v20260116]"
bin/rails "gar:switch[gar_v20260116]"
```

Задачи печатают итог и прогресс, логи гема идут в лог приложения. Если базу держит другая
задача, `gar:update` сообщает об этом и выходит без ошибки. Без Rails задачи подключаются
строкой `load "gar/tasks/gar.rake"` в `Rakefile`.

Обновление по расписанию — `gar:update` из крона или задача Solid Queue
([examples/active_job_update.rb](examples/active_job_update.rb)); ФНС публикует выгрузки по
вторникам и пятницам:

```yaml
# config/recurring.yml
production:
  gar_update:
    command: "Gar::Tasks.new.update"   # или class: GarUpdateJob
    queue: gar
    schedule: every tuesday and friday at 6am
```

## Подключение к базе

База ГАР — отдельная база или кластер, адрес — `GAR_DATABASE_URL` (`DATABASE_URL` гем не читает).
Без адреса первое обращение бросает `Gar::ConfigurationError`.

```ruby
Gar.configure do |config|
  config.database_url = ENV["GAR_DATABASE_URL"] # по умолчанию
  config.pool_size    = 5   # пул соединений поиска на процесс (по соединению на поток Puma)
  config.pool_timeout = 5   # ожидание свободного соединения, с
  config.connect_timeout          = 2 # с; у libpq не меньше 2
  config.search_statement_timeout = 1 # с, только для поиска; nil — без ограничения
end
```

- **Соединения.** Поиск берёт соединение из пула на время вызова и безопасен из нескольких
  потоков; свой запрос — `Gar.with_connection { |conn| … }`. Загрузка, пути, переключение и
  дельты открывают свои соединения без `statement_timeout`.
- **База недоступна** (нет соединения, таймаут, пул занят, в базе нет текущей схемы) — поиск
  бросает `Gar::UnavailableError`: форма может перейти на ручной ввод. `Gar.available?` —
  быстрая проверка без исключения (подходит для health-эндпоинта).
- **Fork.** После `fork` (Puma в кластерном режиме, Solid Queue) гем открывает свои соединения.
  На macOS добавьте в адрес `gssencmode=disable`: libpq с Kerberos падает в форкнутом процессе.
- **Пользователи.** Поиску достаточно чтения, загрузке нужны права на схемы — удобно завести
  читателя для приложения и импортёра для `gar:*` и фоновых задач:

```sql
CREATE ROLE gar_importer LOGIN PASSWORD '…';
CREATE ROLE gar_reader   LOGIN PASSWORD '…';
GRANT CONNECT, CREATE, TEMPORARY ON DATABASE gar_db TO gar_importer;
GRANT CONNECT ON DATABASE gar_db TO gar_reader;
-- схемы создаются заново при каждом полном импорте
ALTER DEFAULT PRIVILEGES FOR ROLE gar_importer GRANT USAGE ON SCHEMAS TO gar_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE gar_importer GRANT SELECT ON TABLES TO gar_reader;
```

Схемы, созданные раньше: `GRANT USAGE ON SCHEMA gar TO gar_reader; GRANT SELECT ON ALL TABLES IN
SCHEMA gar TO gar_reader;`.

**Инструментирование.** С ActiveSupport каждый вызов поиска публикует событие `search.gar`
(`method`, `query`/`guid`, `schema`, `count`):

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

Gar.update! # базы нет — скачивание (только 43 и 11), импорт, пути, переключение; дальше — дельты

Gar.autocomplete("Киров, Ленина 10б").each { puts _1.address }
Gar.address(house_guid).full_address
```

Примеры скриптов — в [examples/](examples/).

### Загрузка из приложения

Шаги вызываются по отдельности, например из фоновой задачи, и сообщают прогресс через
`on_progress: ->(done, total, stage) {}`; ошибки — исключения гема (`Gar::Error`).

```ruby
progress = ->(done, total, stage) { Rails.logger.info("#{stage}: #{done}/#{total}") }

zip    = Gar.download(on_progress: progress)                   # :download — байты; субъекты — config.region_codes
schema = Gar.import(zip, region_codes: %w[43 11], on_progress: progress) # :import — байты XML, :indexes — таблицы
Gar.build_paths(schema, on_progress: progress)                 # :paths — записи
Gar.switch(schema, on_progress: progress)                      # :switch
Gar.cleanup_schemas                                            # => имена удалённых схем

Gar.current_version # => Gar::Meta текущей схемы (version_id, version_date, region_codes, status…) или nil
Gar.status          # => Gar::Status: current, updates (последние дельты), backups, imports
```

- **Скачивание.** С субъектами гем собирает из архива на сервере частичный zip
  `gar_xml_v<версия>_r11_43.zip`. Обрыв докачивается, ответы 5xx и 429 повторяются
  (`api_retry_attempts`, `api_retry_timeout`). Если сервер не отдаёт части файла, решает
  `config.download_mode`: `:auto` (весь архив с предупреждением), `:partial` (ошибка), `:full`.
- **Схемы.** Импорт идёт в `<database_schema>_v<версия>`, прежняя текущая после `switch` становится
  резервной `<database_schema>_backup_v<версия>`; резервных остаётся `config.keep_backups`.
  Пока новая схема загружается, поиск работает по текущей; переключение — одна транзакция.
- **Повторный запуск безопасен.** Скачанный архив не качается заново, схема, загруженная из той
  же версии с теми же настройками, не загружается повторно, пути достраиваются только пустые.
- **Один процесс за раз.** Изменяющие шаги держат advisory lock PostgreSQL, скачивание —
  блокировку файла; второй процесс получает `Gar::LockedError`.
- **Порядок.** `Gar.switch` переключает только готовую схему (пути построены).
- **Прогресс из потоков.** При импорте в потоках (`in_threads`) `on_progress` вызывается из
  потоков импорта: обработчик, который пишет в базу приложения, берёт соединение сам.

Пример фоновой задачи с отчётом на пульте — [examples/active_job_import.rb](examples/active_job_import.rb).

### Обновление по расписанию (дельты)

```ruby
result = Gar.update!(on_progress: progress) # :download, :delta — байты XML дельты, :merge — слияние
result.kind       # :none — уже последняя версия, :delta — применены дельты, :full — полный импорт
result.versions   # применённые дельты: [20260120, 20260123]
result.to_version # версия базы после обновления
result.reason     # почему полный импорт

# одна полоса на всё обновление: 0..1000, только вперёд, в конце — 1000
Gar.update!(on_overall_progress: ->(done, total) { bar.update(done * 100 / total) })
```

- **Дельты или полный импорт.** Если текущая схема готова, загружена с теми же настройками и её
  версия есть в списке выгрузок ФНС, применяются по порядку все дельты новее неё. Иначе — полный
  импорт последней выгрузки: базы нет, изменились настройки загрузки (субъекты, таблицы, типы
  параметров, `keep_history`, `prune_hierarchy`), цепочка прервана, дельт больше
  `config.max_delta_chain` (30) или прошлый полный импорт старше `config.full_import_interval`
  (30 дней).
- **Зачем периодический полный импорт.** Дельты ФНС неполны: новые дома бывают без записи в
  `AS_HOUSES`, исправления без смены `CHANGEID` в дельты не попадают. Без субъектов это ~50 ГБ
  раз в месяц — увеличьте интервал или отключите его (`nil`).
- **Общий ход.** `on_overall_progress` кладёт стадии на шкалу `Gar::Progress::SCALE` по весам
  `Gar::Progress::FULL` и `DELTA` (на каждую дельту цепочки); 1000 — после очистки схем и архивов.
- **Применение.** Дельта меняет текущую схему в одной транзакции: читатели видят базу до или после
  неё. Упавшая дельта откатывается целиком, применённые остаются — следующий запуск продолжит.
- **Архивы.** После обновления удаляются применённые дельты и старые полные архивы
  (`config.cleanup_downloads = false` — оставить). Файловый сервер ФНС хранит выгрузки ~8 месяцев:
  база, которая дольше не обновлялась, загрузится заново.
- Дельту можно применить и вручную: `Gar::Delta.new.apply(zip)` — без проверки цепочки.

### Настройки загрузки

```ruby
Gar.configure do |config|
  # Субъекты — папки архива; пустой список (по умолчанию) — вся страна
  config.region_codes = %w[43 11]   # можно и числами: [43, 11]

  # Состав данных: :minimal (по умолчанию) — то, что нужно поиску и адресной строке;
  # :extended — плюс участки, помещения, реестр GUID и связи разделения; :full — весь архив.
  # Справочники корня архива грузятся всегда
  config.preset = :minimal
  config.tables += [:steads]        # добавить таблицы субъекта
  config.hierarchies = [:adm]       # только административная иерархия
  config.param_types = [5, 6, 7]    # типы параметров: почтовый индекс, ОКАТО, ОКТМО
  config.keep_history = true        # хранить неактуальные записи
  config.prune_hierarchy = false    # не убирать из иерархий строки незагруженных объектов

  # Скачивание
  config.full_base_dir = "storage/gar/full_base"   # полные и частичные архивы
  config.delta_dir     = "storage/gar/delta"
  config.download_mode = :auto                      # :partial, :full
  config.api_ca_file   = "/etc/ssl/corporate_ca.pem"  # свой УЦ (прокси), если его нет в ОС
  config.api_retry_attempts = 3                     # попыток подряд без прогресса
  config.api_retry_timeout  = 5                     # пауза, с; растёт вдвое
  config.api_read_timeout   = 30

  # Обновление
  config.max_delta_chain      = 30   # больше дельт подряд — полный импорт
  config.full_import_interval = 30   # дней между полными импортами; nil — только дельты
  config.cleanup_downloads    = true # удалять применённые дельты и старые архивы
  config.keep_backups         = 1    # прежних текущих схем после переключения

  # Импорт: файлы «таблица × субъект» параллельно, крупные первыми
  config.parallel_import_workers = 2         # по умолчанию — число ядер, но не больше 4
  # config.parallel_import = false           # без воркеров: медленнее, минимум памяти
  # config.import_maintenance_work_mem = "256MB" # память PostgreSQL на индексы на воркер
end
```

- Без `keep_history` загружаются только актуальные записи; параметры — только действующие и
  только типов `config.param_types`. С `prune_hierarchy` (по умолчанию) в иерархиях остаются
  только объекты загруженных таблиц.
- XML читается потоком из zip с проверкой CRC32, процесс импорта занимает около 100 МБ памяти.
  На Linux воркеры — форки запустившего процесса: импорт запускают задачей (rake, фоновый
  воркер), а не в процессе веб-сервера.
- **`gar_meta`** — сведения о схеме (одна строка): версия и дата выгрузки, субъекты, таблицы,
  настройки, версия гема и статус — `importing`, `imported`, `ready` (пути построены).
  Прочитать — `Gar::Meta.read(conn, schema)` или `Gar.current_version`.
- **Пути.** `Gar.build_paths` заполняет у объектов и домов `full_adm_path`/`full_mun_path`
  («Кировская обл, Киров г, Ленина ул, д. 14 к. 1 стр. 3») и `adm_path_ids`/`mun_path_ids`,
  число домов и признак центра субъекта. Без путей не работают полнотекстовый поиск, `within:`
  и автодополнение; каскадный поиск, `Gar.address` и `match_house` работают.

### Низкоуровневый API

```ruby
downloader = Gar::Downloader.new
info = downloader.latest_version                  # => { "VersionId" => 20261002, "GarXMLFullURL" => …, "GarXMLDeltaURL" => … }
downloader.all_versions                           # все выгрузки, которые есть на сервере
zip   = downloader.download_full_base(info, region_codes: %w[43 11]) # => "…/gar_xml_v20261002_r11_43.zip"
delta = downloader.download_delta(info)

importer = Gar::Importer.new(conn)                # conn — PG::Connection; без него — своё соединение
schema   = importer.import_full_base(zip, schema: "gar_check", region_codes: %w[43])
Gar::PathBuilder.new(conn, schema:).build
importer.switch_to_imported_schema(schema)

Gar::PathBuilder.new(conn).invalidate([street_object_id]) # очистить пути улицы и её домов, затем build
Gar::Delta.new(conn).apply(delta)                 # дельта к текущей схеме, без проверки цепочки
```

### Автодополнение

```ruby
Gar.autocomplete("Киров, Ленина 10б", region_codes: %w[43 11], limit: 10)
# => [#<data Gar::Suggestion kind=:house, object_guid="…", gar_object_id=…, level=10, region_code="43",
#       name="д. 10б", address="Кировская обл, Киров г, Ленина ул, д. 10б", exact=true>,
#     …, #<data Gar::Suggestion kind=:address_object, name="Ленина ул", …, exact=false>]
Gar.autocomplete("Ленина 12 к2", within: kirov_guid) # только в поддереве города
Gar.autocomplete("Ленина 13").select(&:exact)        # дома «13» на подходящих улицах, без «13а» и «13 к. 1»
```

- Строка делится на текст и номер дома: «10», «10а», «10 лит. А», «10/2», «12 к2»,
  «14 корп. 1 стр. 3», слитно — «14к1с3». Тип дома перед номером («д. 10») и помещение после
  него («кв. 5») не мешают. Шесть цифр — почтовый индекс.
- Без номера — адресные объекты по тексту (последнее слово — префикс). С номером — дома на
  подходящих улицах: точный номер, затем номера, начинающиеся с введённого; после домов — улицы.
- `exact` — номер совпал целиком (с литерой, корпусом и строением, без других дополнительных
  номеров), как `:exact` у `Gar.match_house`. Точных бывает несколько: одноимённые улицы,
  «д. 40» и «зд. 40».
- Элементы — `Data` с `to_h`/`as_json`/`to_json`.

### Адрес по GUID

Разобранные поля и строки по правилам ФНС (`docs/Правила_формирования_адресной_строки.docx`):

```ruby
address = Gar.address(house_guid, hierarchy: :mun)
address.full_address  # => "Московская область, городской округ Павлово-Посадский, город Павловский Посад, улица Тихонова, дом 93"
address.short_address # => "Московская область, г.о. Павлово-Посадский, г Павловский Посад, ул Тихонова, д. 93"
address.to_h
# => { object_guid:, gar_object_id:, level:, hierarchy:, region_code: "50", region: "Московская область",
#      district: "городской округ Павлово-Посадский", city: "город Павловский Посад", city_guid:,
#      street: "улица Тихонова", street_guid:, house: "93", building: nil, structure: nil,
#      house_element: #<data Gar::HouseElement …>, postal_code:, okato:, oktmo:, parent_guids: [...],
#      elements: [#<data Gar::AddressElement …>, …], full_address:, short_address: }

# Части с кратким типом — для своей адресной строки
street = address.street_element   # nil — улицы нет
street.short_name                 # => "ул Тихонова"
city = address.city_element
[city.name, city.short_type]      # => ["Павловский Посад", "г"]
city.full_type                    # => "город"

# Дом: номер с литерой, тип и все дополнительные номера
house = Gar.address(guid_of_d_18_litera_b).house_element  # «д. 18 литера Б»
house.number                      # => "18Б" (то же в address.house)
[house.short_type, house.full_type]  # => ["д.", "дом"]
Gar.address(guid_of_d_5_soor_1).house_element.additions
# => [#<data Gar::HouseAddition short_type="соор.", full_type="сооружение", number="1">]

Gar.address([guid1, guid2, unknown]) # пачка => { guid1 => #<data Gar::Address …>, …, unknown => nil }

Gar.address_status(guid)  # почему nil: снесён, упразднён или такого GUID нет
# => #<data Gar::AddressStatus status=:inactive, level=10, update_date=#<Date 2025-06-01>,
#      operation_type_id=30, operation="Ликвидация", …>
```

- `nil` — нет действующего объекта с таким GUID; причину даёт `Gar.address_status`: `:active`,
  `:inactive` (с датой и типом операции) или `:not_found`.
- `elements` — адресные объекты по порядку (`Gar::AddressElement`: `name` без типа, `short_type`,
  `full_type`, `short_name`, `full_name`); у дома — от субъекта до родителя. Краткие типы ФНС
  меняет между выгрузками, поэтому берите их отсюда, а не собирайте сами.
- `house` — номер с литерой в регистре ГАР («18Б», «10/2»); `building` и `structure` — корпус и
  строение из дополнительных номеров; тип самого дома — не часть номера (у «стр. 9» `house` — «9»,
  `structure` — `nil`). `house_element` — дом целиком: тип и все дополнительные номера.
- `city` — самый глубокий элемент уровня 5–6 или с типом «город»; `street` — самый глубокий
  элемент уровня 7 (СНТ, микрорайон) или 8 (улица). Родитель дома не всегда улица — смотрите
  `street_guid`, а не `parent_guids.last`.
- Индекс, ОКАТО и ОКТМО — параметры объекта, индекс — при отсутствии у ближайшего предка.

### Перенос старых адресов

GUID улицы ФИАС (`AOGUID`) в ГАР сохранён как `OBJECTGUID`. Проверка на своих данных —
`ruby examples/verify_fias_guids.rb streets.csv > report.tsv`.

```ruby
Gar.match_house(street_guid:, number: "12", building: "2")
# => #<data Gar::HouseMatch status=:exact, house=#<data Gar::House house_num="12", …>, alternatives=[…]>
Gar.match_house(street_guid:, number: "12 корп. 2")  # то же
Gar.match_house(street_guid:, number: "10", letter: "А")
```

- `:exact` — совпали номер, корпус и строение; `:fuzzy` — единственный дом с тем же номером и
  чем-то сверх записанного (записано «14», в ГАР — «14 к. 1 стр. 3»); `:none` — иначе, в том числе
  если подходят несколько домов.
- Номера сравниваются без учёта регистра, пробелов и латиницы вместо кириллицы; литера — часть
  номера, корпус и строение — из аргументов или самого номера («12к2»).
- `alternatives` — другие дома улицы с тем же числом в номере, для ручного выбора.

### Поиск (`Gar::Search`)

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

- Результаты — `Gar::AddressObject` и `Gar::House` (`Data`): `gar_object_id` (OBJECTID),
  `object_guid`, название или номер с типом, `region_code`, оба пути; у объекта — `level` и `active`.
- Общие параметры поиска и автодополнения: `hierarchy:` (`:adm` по умолчанию или `:mun`;
  незагруженная иерархия — `Gar::ConfigurationError`), `region_codes:`, `within:` — GUID субъекта,
  района или города.
- Запрос: регистр, `ё` и знаки препинания не важны, слова ищутся с синонимами — из справочников
  типов ГАР («ул» ↔ «улица»), встроенного словаря (`lib/gar/data/synonyms.yml`, отключается
  `config.builtin_synonyms = false`) и своих групп:
  `Gar.configure { |config| config.synonyms = { "проспект" => %w[прсп] } }`.
- Порядок: совпадения названия целиком, затем центр субъекта и его улицы, затем объекты с бóльшим
  числом домов. Если ничего не нашлось из-за типа объекта, которого нет в пути, запрос повторяется
  без него.

**Скорость и качество** (субъекты 43 и 11, PostgreSQL 18, Apple M2 Max, p50 / p95):

| Запрос | p50 | p95 |
|---|---:|---:|
| `Gar.autocomplete`: начало названия улицы | 1,2–1,5 мс | 1,7–2,8 мс |
| `Gar.autocomplete`: улица и номер дома | 11–16 мс | 38–49 мс |
| `Gar.autocomplete`: улица и номер в границах города | 2,8–3,1 мс | 5,3–6,1 мс |
| `Gar.address` по GUID дома | 2,4–2,5 мс | 3,2–3,8 мс |
| `search_houses` «улица номер» | 1,5–1,7 мс | 4,6–6,4 мс |

На 32 типичных вводах (`examples/benchmarks/search_quality.rb`) ожидаемый адрес первым в 97 %
случаев и в первой тройке — во всех.

### Тестовые данные для спек приложения

```ruby
# spec/rails_helper.rb
require "gar/test_support"

RSpec.configure do |config|
  config.before(:suite) { Gar::TestSupport.load_fixtures } # схема config.database_schema
end

Gar::TestSupport::Sample.guid(4_300_106) # GUID объекта набора по OBJECTID: «Ленина 14 к. 1 стр. 3» в Кирове
```

`load_fixtures(conn = nil, schema:)` загружает небольшой связный набор `Gar::TestSupport::Sample`
так же, как импорт реального архива, по текущим настройкам. В наборе — Кировская обл. (г. Киров
с домами разных видов: литера, корпус, строение, сооружение, дробь; посёлок без улиц, СНТ),
Коми (Сыктывкар — центр субъекта, Ухта), улица Москвы и цепочка из правил ФНС (Московская обл.).
Заменяется только схема, созданная `load_fixtures`, или пустая.

## Схема базы данных

По таблице на каждый файл архива ГАР (`Gar::Schema`); набор `:minimal`:

- `address_objects` — адресные объекты (регионы, города, улицы)
- `houses` — здания и сооружения с дополнительными номерами и `house_num_norm` — номером для
  сравнения
- `adm_hierarchy`, `mun_hierarchy` — административная и муниципальная иерархии
- `addr_obj_params`, `house_params` — параметры (индекс, ОКАТО, ОКТМО…)
- справочники типов, уровней, параметров и операций

У объектов и иерархий есть `region_code`. Служебные таблицы: `gar_meta` — сведения о схеме,
`gar_updates` — журнал применённых дельт.

## Источники данных

- Список выгрузок — API ФНС `https://fias.nalog.ru/WebServices/Public/GetAllDownloadFileInfo`
  (`config.api_all_versions_url`).
- Архивы — `https://fias-file.nalog.ru/downloads/<ГГГГ.ММ.ДД>/`, хранятся ~8 месяцев. На сотни
  быстрых запросов сервер отвечает 503 примерно на час; гем обращается к нему последовательно
  (частичная загрузка двух субъектов — 26 запросов).
- Если сеть подменяет сертификат (корпоративный прокси), укажите его УЦ в `config.api_ca_file`;
  `config.api_ssl_verify = false` — только для отладки.
- Структура архива — `docs/gar_archive_structure.md`, инструменты — `examples/tools/`.

## Известные ограничения

- **Опечатки** поиск не исправляет: «Лениа» не найдёт «Ленина».
- **Стемминг с префиксом:** на «Киров» в выдаче бывает «Кирс».
- **Справочники типов:** смена краткого имени типа в дельте не пересобирает пути домов — их
  обновит следующий полный импорт или `Gar.build_paths` после `PathBuilder#invalidate`.
- **Дельты ФНС неполны:** между полными импортами в базе может не хватать новых домов.
- **Наборы `:extended`/`:full`:** участки и помещения загружаются, но в путях, поиске и
  `Gar.address` не участвуют.

## Разработка

```bash
bin/setup_test_db                 # тестовый PostgreSQL на :6433 (без Docker)
bundle exec rspec                 # все тесты; :slow — с GAR_SLOW_TESTS=1
bundle exec rubocop
```

Окружение, правила проекта и команды — [DEVELOPMENT.md](DEVELOPMENT.md), проверка на реальных
данных — `docs/real_data_checklist.md`. CI проверяет Ruby 3.3, 3.4 и 4.0 с PostgreSQL 18 и Ruby 3.4
с PostgreSQL 16. Изменения версий — [CHANGELOG.md](CHANGELOG.md).

## Лицензия

[MIT License](https://opensource.org/licenses/MIT). Гем не связан с Федеральной налоговой службой
России или каким-либо государственным органом; данные ГАР предоставляются публично и «как есть».
