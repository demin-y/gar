# Руководство для разработчиков GAR

Этот документ содержит подробные инструкции по настройке окружения разработки, архитектуре и лучшим практикам.

## Содержание

- [Архитектура инфраструктуры](#архитектура-инфраструктуры)
- [DevContainer детали](#devcontainer-детали)
- [Docker Compose структура](#docker-compose-структура)
- [Работа с базами данных](#работа-с-базами-данных)
- [Тестирование](#тестирование)
- [Правила проекта](#правила-проекта)
- [Лучшие практики](#лучшие-практики)
- [Troubleshooting](#troubleshooting)

## Архитектура инфраструктуры

Проект использует гибридный подход:
- **DevContainer** для полностью изолированной среды разработки
- **docker-compose.yml** для управления БД (используется и DevContainer, и локально)
- **Makefile** для унифицированного интерфейса

### Компоненты

```
┌─────────────────────────────────────────────────────────┐
│                    DevContainer (опционально)            │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Workspace Container                             │   │
│  │  - Ruby 3.4.5                                   │   │
│  │  - Bundle gems                                   │   │
│  │  - Git, Docker CLI                               │   │
│  └──────────────┬──────────────────────────────────┘   │
│                 │ подключается к                       │
└─────────────────┼──────────────────────────────────────┘
                  │
    ┌─────────────┴─────────────┐
    │   docker-compose.yml      │
    │                           │
    ├───────────┬───────────────┤
    │           │               │
┌───▼────┐  ┌──▼─────┐   ┌─────▼────┐
│db-dev  │  │db-test │   │workspace │
│6432    │  │6433    │   │(devcon)  │
└────────┘  └────────┘   └──────────┘
```

## DevContainer детали

### Структура файлов

```
.devcontainer/
├── Dockerfile          # Образ с Ruby 3.4.5 и инструментами
└── devcontainer.json   # Конфигурация VS Code / JetBrains
```

### Dockerfile особенности

- **База:** `ruby:3.4.5-slim`
- **Пользователь:** `vscode` (non-root для безопасности)
- **Важно:** НЕ копирует Gemfile в образ (используется volume mount)
- **Bundle:** Устанавливается через `postCreateCommand`

### Жизненный цикл DevContainer

1. **Build:** Docker собирает образ из `.devcontainer/Dockerfile`
2. **Compose:** Запускает `docker-compose.yml` (workspace + db-dev + db-test)
3. **Mount:** Монтирует проект в `/workspace`
4. **postCreateCommand:** Выполняет `bundle install`
5. **Ready:** Все сервисы готовы к работе

### Переменные окружения

| Переменная | Значение | Описание |
|------------|----------|----------|
| `GAR_DATABASE_URL` | `postgresql://postgres:postgres@db-dev:5432/gar_db_dev` | Dev БД гема |
| `RUBY_VERSION` | `3.4.5` | Версия Ruby |
| `BUNDLE_GEMFILE` | `/workspace/Gemfile` | Путь к Gemfile |

### VS Code расширения

Автоматически устанавливаются:
- `Shopify.ruby-lsp` - Ruby LSP сервер
- `castwide.solargraph` - Ruby intellisense
- `ms-azuretools.vscode-docker` - Docker поддержка
- `mtxr.sqltools` + `mtxr.sqltools-driver-pg` - SQL клиент
- `redhat.vscode-yaml` - YAML поддержка

## Docker Compose структура

### services

#### `workspace` (только для DevContainer)
- Контейнер для разработки
- Монтирует код через volume
- Зависит от `db-dev` и `db-test`

#### `db-dev` (dev БД)
- Postgres 17
- Порт: `6432:5432`
- Volume: `postgres_dev_data`
- Healthcheck: каждые 10 секунд

#### `db-test` (test БД)
- Postgres 17
- Порт: `6433:5432`
- Volume: `postgres_test_data`
- Пустая: данные загружают спеки (`Gar::TestSupport.load_fixtures`)
- Healthcheck: каждые 5 секунд

### Volumes

| Volume | Назначение |
|--------|------------|
| `postgres_dev_data` | Данные dev БД (персистентные) |
| `postgres_test_data` | Данные test БД (персистентные) |
| `bundle_cache` | Кеш установленных gems |

### Сеть

Все сервисы в одной сети `gar_network` (bridge mode).

### Подключение к БД

#### Внутри DevContainer:
```bash
# Dev БД
psql postgresql://postgres:postgres@db-dev:5432/gar_db_dev

# Test БД
psql postgresql://postgres:postgres@db-test:5432/gar_db_test
```

#### С хоста (локально):
```bash
# Dev БД
psql postgresql://postgres:postgres@localhost:6432/gar_db_dev

# Test БД
psql postgresql://postgres:postgres@localhost:6433/gar_db_test
```

## Работа с базами данных

### Тестовые данные (test БД)

Набор `Gar::TestSupport::Sample` (`lib/gar/test_support/sample.rb`) загружается перед спеками
через `Gar::TestSupport.load_fixtures` в схему `gar` тем же импортом, что и реальный архив:
DDL из `Gar::Schema`, затем `PathBuilder`. Ручных `*.sql` нет — новые колонки и таблицы
попадают в фикстуры сами.

### Сброс БД

```bash
# Dev БД - удаляет volume, пересоздает контейнер
make dev-db-reset

# Test БД - удаляет volume, пересоздает пустую
make test-db-reset
```

### Миграции

Проект использует версионированные схемы (`gar_v20241201`). При импорте:
1. Создается новая схема
2. Импортируются данные
3. `switch_to_imported_schema` делает атомарную замену

### Бекапы

```bash
# Бекап dev БД
docker-compose exec db-dev pg_dump -U postgres gar_db_dev > backup.sql

# Восстановление
docker-compose exec -T db-dev psql -U postgres gar_db_dev < backup.sql
```

## Тестирование

### Стратегия

- **Unit тесты:** Не требуют БД
- **Тесты с тегом `:db`:** Используют test БД со схемой `gar` из `Gar::TestSupport`

### spec_helper.rb логика

```ruby
# before(:suite)
1. Запускает docker-compose up -d db-test
2. Ждет готовности БД (healthcheck)
3. Задаёт config.database_url = TEST_DATABASE_URL

# after(:suite)
1. Закрывает подключения
2. ОСТАВЛЯЕТ db-test запущенной (для отладки)
```

### Запуск тестов

```bash
# Все тесты
make test

# Конкретный файл
bundle exec rspec spec/gar/search_spec.rb

# Отладка (оставить БД запущенной)
bundle exec rspec spec/gar/importer_spec.rb
make test-db-psql  # Проверить данные вручную
```

## Правила проекта

### Ветки и версии

- `main` — выпущенные версии; работа идёт в своей ветке от `main`, в `main` — через PR с
  описанием: что сделано, как проверено, что сознательно не сделано.
- Версии — SemVer: исправление — 2.0.x, новое без ломки API — 2.x.0; публичный API 2.x не
  ломаем без новой мажорной версии. Каждое заметное изменение — в CHANGELOG, раздел «Не выпущено».
- Выпуск: `Gar::VERSION`, в CHANGELOG «Не выпущено» → «[x.y.z] — дата», аннотированный тег
  `vx.y.z` на коммите выпуска в `main`. Гем ставится из GitHub по тегу, на RubyGems не публикуется.
- Перед PR: `bundle exec rubocop` — без замечаний, `bundle exec rspec` — зелёный.

### Команды

```bash
bin/setup_test_db                          # тестовый PostgreSQL на :6433 без Docker (идемпотентно)
bundle exec rspec                          # все тесты; :slow — с GAR_SLOW_TESTS=1
bundle exec rspec spec/integration         # сквозной конвейер на синтетическом архиве
bundle exec rubocop
python3 examples/tools/gar_toc.py <zip|URL> 43 11   # оглавление архива ГАР без распаковки
ruby examples/tools/check_consistency.rb gar        # реальные данные: инварианты, пересчёт путей и рангов
ruby examples/tools/compare_schemas.rb gar gar_full # две схемы: цепочка дельт против полной выгрузки
ruby examples/benchmarks/search_quality.rb          # качество автодополнения (queries_43_11.yml)
```

- `TEST_DATABASE_URL` по умолчанию `postgresql://postgres:postgres@localhost:6433/gar_db_test`.
- На macOS в адрес базы — `?gssencmode=disable`: libpq с Kerberos падает после `fork`.
- К fias-file.nalog.ru — только последовательно и редко: на сотни быстрых запросов сервер
  включает защиту от ботов (503) примерно на час.
- Справка: структура реального архива и объёмы — `docs/gar_archive_structure.md`, форматы XML —
  `docs/xml_schema/*.xsd`, правила адресной строки ФНС — `docs/Правила_формирования_адресной_строки.docx`.

### Тесты

- Без тега — unit-тесты, работают без БД. Тег `:db` — БД подключается лениво, фикстуры
  (`Gar::TestSupport::Sample`) заливаются автоматически в схему `gar`.
- Свои схемы в `:db`-примерах — через `isolated_schema` / `register_schema_for_cleanup`
  (удаляются после примера). Конфигурация гема сбрасывается перед каждым примером.
- Синтетический архив с реальной структурой — `GarArchiveBuilder`; готовый связный набор
  (Киров 43, Коми 11, Москва 77, пустой 80) — `GarSampleArchive.build`.
- Проверяем публичное поведение и результат; моки — только на внешних границах (HTTP, время).
  Приватные методы через `send` не тестируем.
- Известная, ещё не исправленная ошибка — пример с `pending "Ошибка N: …"`.
- Исправление ошибки — по возможности с примером, который без исправления падает.

### Код

- Комментарии, сообщения логов и исключений — на русском.
- Ruby ≥ 3.3, `# frozen_string_literal: true`, двойные кавычки, rubocop из `.rubocop.yml`.
- В `lib/` никаких `puts`/`print`/`exit`: логгер `Gar.logger` и исключения гема (`Gar::Error`).
  Исключение — `lib/gar/tasks.rb` (rake-задачи `gar:*`): итог и прогресс печатаются в `$stdout`,
  их читает человек или крон в консоли.
- Имена схем и таблиц в SQL — через `quote_ident`; значения — через параметры.

## Лучшие практики

### Разработка

1. **Используйте DevContainer** для консистентности окружения
2. **Запускайте rubocop** перед коммитом
3. **Пишите тесты** для новой функциональности
4. **Используйте dev БД** для экспериментов, не test БД

### Тестирование

1. **Изолированные тесты:** Каждый тест не зависит от других
2. **Fixtures:** Минимальные данные, достаточные для тестов
3. **Моки:** Мокайте внешние API (fias.nalog.ru)

### Производительность

1. **Test БД:** Fixtures автоматически загружаются
2. **Parallel import:** `parallel_import: true` для больших импортов
3. **Объём:** импортируйте только нужное — `config.preset` и `region_codes:`

### Отладка

```bash
# Открыть psql в test БД
make test-db-psql

# Посмотреть логи test БД
make test-db-logs

# Запустить один тест с pry
bundle exec rspec spec/gar/search_spec.rb:42
```

### Очистка

```bash
# Полная очистка (volumes + контейнеры)
make clean

# Очистка только test БД
make test-db-reset

# Очистка bundle cache
rm -rf vendor/bundle .bundle
bundle install
```

## Troubleshooting

### DevContainer не запускается

```bash
# Пересоздать контейнеры
docker-compose down -v
# Переоткрыть в VS Code → "Reopen in Container"
```

### БД не доступна

```bash
# Проверить статус
make db-status

# Перезапустить
make db-down
make db-up
```

### Тесты падают с ошибкой подключения

```bash
# Сбросить test БД
make test-db-reset

# Проверить подключение
make test-db-psql
```

### Проблемы с bundle install

```bash
# В DevContainer
bundle install

# Локально
rm -rf vendor/bundle
bundle install
```

### "Port already in use"

```bash
# Найти процесс
lsof -ti:6432
lsof -ti:6433

# Остановить контейнеры
make db-down
```

### "Database does not exist"

```bash
# Пересоздать БД
make dev-db-reset
# или
make test-db-reset
```

### Контейнер БД перезапускается по кругу

В логе `database files are incompatible with server` — том создан прежней версией PostgreSQL
(например, 13), а образ — 17. Данные test-БД пересоздаются спеками, поэтому том можно удалить:
`make test-db-reset`; dev-БД — `make dev-db-reset` (её данные пропадут).

### Fixtures не применяются

```bash
# Удалить volume test БД
docker volume rm gar_postgres_test_data

# Пересоздать
make test-db-reset
```

## Дополнительные ресурсы

- [PostgreSQL Documentation](https://www.postgresql.org/docs/current/)
- [RSpec Best Practices](https://rspec.info/)
- [RuboCop Style Guide](https://rubocop.org/)
- [Dev Containers Specification](https://containers.dev/)
