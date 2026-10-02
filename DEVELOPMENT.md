# Руководство для разработчиков GAR

Этот документ содержит подробные инструкции по настройке окружения разработки, архитектуре и лучшим практикам.

## Содержание

- [Архитектура инфраструктуры](#архитектура-инфраструктуры)
- [DevContainer детали](#devcontainer-детали)
- [Docker Compose структура](#docker-compose-структура)
- [Работа с базами данных](#работа-с-базами-данных)
- [Тестирование](#тестирование)
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
| `DATABASE_URL` | `postgresql://postgres:postgres@db-dev:5432/gar_db_dev` | Dev БД |
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
- Postgres 16
- Порт: `6432:5432`
- Volume: `postgres_dev_data`
- Healthcheck: каждые 10 секунд

#### `db-test` (test БД)
- Postgres 16
- Порт: `6433:5432`
- Volume: `postgres_test_data`
- Auto-init: загружает `spec/fixtures/*.sql`
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

### Fixtures (test БД)

Файлы в `spec/fixtures/`:
- `schema.sql` - DDL (создание таблиц, индексов)
- `data.sql` - Тестовые данные (INSERT)

Применяются автоматически при создании db-test через `docker-entrypoint-initdb.d`.

### Сброс БД

```bash
# Dev БД - удаляет volume, пересоздает контейнер
make dev-db-reset

# Test БД - удаляет volume, пересоздает с fixtures
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
- **Integration тесты:** Используют test БД с fixtures

### spec_helper.rb логика

```ruby
# before(:suite)
1. Запускает docker-compose up -d db-test
2. Ждет готовности БД (healthcheck)
3. Устанавливает DATABASE_URL для Gar

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

### Fixtures не применяются

```bash
# Удалить volume test БД
docker volume rm gar_postgres_test_data

# Пересоздать
make test-db-reset
```

## Дополнительные ресурсы

- [PostgreSQL 16 Documentation](https://www.postgresql.org/docs/16/)
- [RSpec Best Practices](https://rspec.info/)
- [RuboCop Style Guide](https://rubocop.org/)
- [Dev Containers Specification](https://containers.dev/)
