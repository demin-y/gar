# GAR - Ruby Gem для работы с Государственным адресным реестром

[![CI](https://github.com/demin-y/gar/actions/workflows/ci.yml/badge.svg)](https://github.com/demin-y/gar/actions/workflows/ci.yml)
[![Ruby](https://img.shields.io/badge/ruby-3.1+-red.svg)](https://www.ruby-lang.org/)
[![Gem Version](https://badge.fury.io/rb/gar.svg)](https://badge.fury.io/rb/gar)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

GAR (Государственный адресный реестр) - это Ruby gem, который предоставляет функциональность для работы с данными Государственного адресного реестра России. Позволяет скачивать, парсить и искать российские адреса вплоть до уровня дома.

## Возможности

- Скачивание полной базы ГАР с fias.nalog.ru
- Скачивание инкрементальных обновлений (в разработке)
- Парсинг XML данных и импорт в PostgreSQL
- Полнотекстовый поиск адресов с автодополнением и поддержкой естественного языка
- Каскадный поиск по уровням ГАР (регионы → города → улицы → дома)
- Поиск адресов по уникальному GUID
- Построение полных строк адресов из ID объектов
- Валидация компонентов адреса
- Поддержка муниципальной и административной иерархий

## Установка

Добавьте эту строку в Gemfile вашего приложения:

```ruby
gem 'gar'
```

Затем выполните:

    $ bundle install

Или установите самостоятельно:

    $ gem install gar

## Требования

- Ruby 3.1+
- PostgreSQL 11+
- Минимум 150GB свободного места для полной базы ГАР

## Настройка

1. Создайте базу данных PostgreSQL:
```sql
CREATE DATABASE gar_db;
```

2. Укажите базу ГАР — переменной окружения или в настройке:
```bash
export GAR_DATABASE_URL="postgresql://user:password@localhost/gar_db"
```

Гем **не читает `DATABASE_URL`**: в Rails-приложении это база самого приложения. Без
настройки первое обращение к базе бросает `Gar::ConfigurationError`.

```ruby
Gar.configure do |config|
  config.database_url = ENV["GAR_DATABASE_URL"] # по умолчанию
  config.pool_size    = 5   # пул соединений поиска (по соединению на поток Puma)
  config.pool_timeout = 5   # ожидание свободного соединения, с
  config.connect_timeout          = 2 # с; у libpq не меньше 2
  config.search_statement_timeout = 1 # с, только для поиска; nil — без ограничения
end
```

**Соединения.** Поиск берёт соединение из пула на время вызова, поэтому `Gar::Search`
можно вызывать из нескольких потоков; свой запрос — `Gar.with_connection { |conn| … }`.
Импорт и построение путей открывают свои соединения без `statement_timeout`. Если база
недоступна, истёк таймаут запроса или пул занят дольше `pool_timeout`, поиск бросает
`Gar::UnavailableError`: приложение может переключить форму на ручной ввод.
`Gar.available?` — быстрая проверка (база отвечает, текущая схема есть, пути построены);
подходит и для health-эндпоинта, нужен только `SELECT`.

**Fork.** После `fork` (Puma в кластерном режиме, Solid Queue) дочерний процесс не трогает
соединения родителя: гем отбрасывает их без закрытия и открывает свои. На macOS `libpq`
с Kerberos падает в форкнутом процессе — добавьте `gssencmode=disable` в строку
подключения: `postgresql://…/gar_db?gssencmode=disable`.

**Инструментирование.** Если загружен ActiveSupport, каждый вызов поиска публикует событие
`search.gar` (`method`, `query`/`guid`, `schema`, `count`) — оно видно в логах и APM:

```ruby
ActiveSupport::Notifications.subscribe("search.gar") do |event|
  Rails.logger.info "ГАР #{event.payload[:method]}: #{event.duration.round(1)} мс, #{event.payload[:count]}"
end
```

## Использование

Gem предоставляет три основных компонента для работы с ГАР:

1. **Downloader** — загрузка данных с fias.nalog.ru
2. **Importer** — импорт данных в PostgreSQL
3. **Search** — полнотекстовый поиск адресов

### Быстрый старт

```ruby
require "gar"

# 1. Настройка подключения к БД
Gar.configure do |config|
  config.database_url = 'postgresql://localhost/gar_db'
  config.database_schema = 'gar'
  # config.logger = false  # без логов; по умолчанию — Rails.logger (если есть) или $stdout
end

# 2. Скачивание полной базы данных
downloader = Gar::Downloader.new
latest_version = downloader.latest_version
zip_path = downloader.download_full_base(latest_version)

# 3. Импорт данных в PostgreSQL
importer = Gar::Importer.new
schema_name = importer.import_full_base(zip_path)

# 4. Построение полных адресных путей (требуется для поиска!)
Gar::PathBuilder.new(schema: schema_name).build

# 5. Переключение на новую схему
importer.switch_to_imported_schema(schema_name)

# 6. Поиск адресов
search = Gar::Search.new
results = search.search_address_objects("Москва Ленина", limit: 10)
results.each { |r| puts r.full_adm_path }
```

> 💡 **Полные рабочие примеры** доступны в папке [examples/](examples/):
> - [1_download_full_database.rb](examples/1_download_full_database.rb) — загрузка полной базы
> - [2_import_full_base.rb](examples/2_import_full_base.rb) — импорт с настройками
> - [3_populate_full_paths.rb](examples/3_populate_full_paths.rb) — построение адресных путей
> - [4_switch_to_imported_schema.rb](examples/4_switch_to_imported_schema.rb) — переключение схем
> - [5_search.rb](examples/5_search.rb) — примеры поиска

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
zip_path = importer.find_latest_full_base_zip

# Импорт с созданием версионированной схемы
# Схема будет названа gar_v20241201 (дата из архива)
schema_name = importer.import_full_base(zip_path)

# Переключение на новую схему (старая сохраняется как резервная)
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

  # Тонкая настройка поверх набора
  config.tables += [:steads]        # добавить таблицы субъекта
  config.hierarchies = [:adm]       # только административная иерархия
  config.param_types = [5, 6, 7]    # типы параметров: почтовый индекс, ОКАТО, ОКТМО
  config.keep_history = true        # хранить неактуальные записи
end

# Только папки нужных субъектов (по умолчанию все)
importer.import_full_base(zip_path, region_codes: ["43", "11"])
```

XML читается потоком прямо из zip: распаковка на диск не нужна, целостность каждого файла
проверяется по CRC32 из оглавления. Версия берётся из `version.txt` внутри архива. Первичные
ключи и индексы строятся после загрузки данных, по таблицам параллельно.

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

`build` заполняет `full_adm_path`/`full_mun_path` и их `tsvector` у `address_objects` и `houses`
и строит полнотекстовые индексы. Какие пути строить, решает состав схемы: путь по иерархии
строится, только если она загружена (`config.hierarchies`). Путь собирается из действующих
актуальных адресных объектов; дом без номера получает путь своей улицы.

Заполняются только пустые пути, обе иерархии за один проход, батчами по возрастанию `id`: прерванное построение
продолжается повторным `build`, а чтобы пересобрать часть путей, достаточно их очистить.

**Примечание:** Процесс построения путей может занять несколько часов на полной базе. Каскадный поиск (`find_address_objects`, `find_houses`) работает без построения путей.

### 4. Поиск адресов (Search)

```ruby
search = Gar::Search.new

# Полнотекстовый поиск
results = search.search_address_objects("Москва Тверская", limit: 10)
results.each do |result|
  puts "#{result.full_adm_path} (уровень #{result.level})"
end

# Поиск с автодополнением
results = search.search_address_objects("Моск", autocomplete: true, limit: 5)

# Каскадный поиск по уровням
regions = search.find_address_objects(level: 1, limit: 10)
cities = search.find_address_objects(parent_guid: region_guid, level: [5, 6])
streets = search.find_address_objects(parent_guid: city_guid, level: 8)

# Поиск домов
houses = search.find_houses(street_guid, limit: 50)

# Полнотекстовый поиск домов
house_results = search.search_houses("д. 10", limit: 10)

# Поиск по GUID
address = search.find_address_object_by_guid("550e8400-e29b-41d4-a716-446655440000")
house = search.find_house_by_guid("650e8400-e29b-41d4-a716-446655440000")
```

Результаты — `Gar::AddressObject` и `Gar::House` (`Data`): `id`, `gar_id` (OBJECTID ГАР),
`object_guid`, название или номер и тип, `full_adm_path`, `full_mun_path`; у адресного
объекта ещё `level`. Схема — `config.database_schema` или `Gar::Search.new(schema: …)`.

## Схема базы данных

Gem создает в схеме по таблице на каждый файл архива ГАР (описание — `Gar::Schema`).
Набор `:minimal` по умолчанию:

- `address_objects` — адресные объекты (регионы, города, улицы)
- `houses` — здания и сооружения, с дополнительными номерами (корпус, строение)
- `adm_hierarchy`, `mun_hierarchy` — административная и муниципальная иерархии
- `addr_obj_params`, `house_params` — параметры объектов и домов (индекс, ОКАТО, ОКТМО…)
- справочники: `object_levels`, `address_object_types`, `house_types`, `add_house_types`,
  `param_types`, `operation_types`, `apartment_types`, `room_types`, `normative_docs_kinds`,
  `normative_docs_types`

У объектов и иерархий есть колонка `region_code` — код субъекта из имени папки архива.

## Источники данных

Данные скачиваются с официального сервиса ФИАС/ГАР:
- Базовый URL: http://fias.nalog.ru/WebServices/Public
- Полная база: GarXMLFullURL
- Обновления: GarXMLDeltaURL

## Замечания по производительности

- Полный импорт базы занимает 4-8 часов в зависимости от оборудования
- Размер базы: ~30-50GB
- Поисковые запросы оптимизированы с индексами
- Рекомендуется использовать SSD хранилище для лучшей производительности

## Разработка

Проект поддерживает два режима разработки:
1. **DevContainer** (рекомендуется для VS Code / JetBrains)
2. **Локальная разработка** (без контейнеров)

### Вариант 1: DevContainer (рекомендуется)

DevContainer автоматически настраивает полное окружение разработки с Ruby 3.4.5, PostgreSQL и всеми инструментами.

**Требования:**
- [VS Code](https://code.visualstudio.com/) с расширением [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
- [Docker Desktop](https://www.docker.com/products/docker-desktop)

**Быстрый старт:**
1. Откройте проект в VS Code
2. Нажмите `F1` → "Dev Containers: Reopen in Container"
3. Подождите, пока контейнер соберется и зависимости установятся
4. Готово! Обе БД запущены, gems установлены

**Особенности DevContainer:**
- Автоматический `bundle install` при создании
- Обе БД (dev + test) запущены и доступны
- SQL Tools подключения преднастроены (dev и test БД)
- Ruby LSP и RuboCop настроены
- Git интеграция

**Подключение к БД из DevContainer:**
- Dev БД: `db-dev:5432` (или `localhost:6432` с хоста)
- Test БД: `db-test:5432` (или `localhost:6433` с хоста)

### Вариант 2: Локальная разработка

Если вы предпочитаете работать без DevContainer, используйте Makefile.

**Требования:**
- **mise** - менеджер версий
- **Docker** - для PostgreSQL БД

**Быстрый старт:**
```bash
# Первоначальная настройка (установка Ruby и зависимостей)
make setup

# Запуск тестов
make test

# Интерактивная консоль
make console
```

### Управление базами данных

Проект использует ДВЕ раздельные БД:
- **Dev БД** (порт 6432) - для разработки и экспериментов
- **Test БД** (порт 6433) - для запуска тестов (автоматически загружаются fixtures)

**Команды для dev БД:**
```bash
make dev-db-up          # Запустить dev БД
make dev-db-down        # Остановить dev БД
make dev-db-reset       # Сбросить dev БД (удалить volume)
make dev-db-logs        # Показать логи
make dev-db-psql        # Подключиться через psql
make dev-db-shell       # Bash shell в контейнере
```

**Команды для test БД:**
```bash
make test-db-up         # Запустить test БД
make test-db-down       # Остановить test БД
make test-db-reset      # Сбросить test БД (с fixtures)
make test-db-logs       # Показать логи
make test-db-psql       # Подключиться через psql
```

**Команды для обеих БД:**
```bash
make db-up              # Запустить обе БД
make db-down            # Остановить обе БД
make db-reset           # Сбросить обе БД (алиас для совместимости)
make db-status          # Показать статус контейнеров
make db-info            # Показать connection strings
```

### Запуск тестов

```bash
# Автоматический запуск (управляет test БД через spec_helper)
make test

# Или напрямую через RSpec
bundle exec rspec

# Запуск одного файла
bundle exec rspec spec/gar/search_spec.rb

# Запуск конкретного теста
bundle exec rspec spec/gar/search_spec.rb:42
```

**Важно:** Test БД автоматически запускается перед тестами (через `spec_helper.rb`) и остается запущенной для удобства отладки. Для полного сброса используйте `make test-db-reset`.

### Линтер и форматирование

```bash
make rubocop            # Проверка кода
make rubocop-fix        # Автоматическое исправление
```

### Доступные команды

Полный список команд с описанием:
```bash
make help
```

### Connection Strings

```bash
# Development
postgresql://postgres:postgres@localhost:6432/gar_db_dev

# Test
postgresql://postgres:postgres@localhost:6433/gar_db_test
```

## Continuous Integration

Проект использует GitHub Actions для автоматической проверки кода:
- **RuboCop** проверяет стиль кода
- **RSpec** запускает тесты на Ruby 3.1, 3.2, 3.3, 3.4
- **PostgreSQL** используется для integration tests

CI запускается автоматически при push в main и при создании PR.

## Лицензия

Gem доступен как открытый исходный код на условиях [MIT License](https://opensource.org/licenses/MIT).

## Отказ от ответственности

Этот gem не связан с Федеральной налоговой службой России или каким-либо государственным органом. Данные ГАР предоставляются публично и "как есть".
