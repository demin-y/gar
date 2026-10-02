# CLAUDE.md

Ruby-гем `gar`: загрузка, импорт в PostgreSQL и поиск по Государственному адресному реестру (ГАР).
Идёт доработка до 2.0.0 под встраивание в Rails-приложение (портал «Первоисточник»).

## С чего начать

**Работа ведётся по плану `docs/rails_integration_plan.md`** — там статус этапов, чек-листы и
журнал сессий. Выполняй первый незавершённый этап. В конце этапа:

1. `bundle exec rubocop` — без замечаний;
2. `bundle exec rspec` — зелёный;
3. `/simplify` по диффу этапа;
4. отметить пункты в плане и дописать запись в «Журнал сессий»;
5. commit и `git push -u origin rails-integration`;
6. открыть PR `rails-integration` → `release-2` «Этап N: …» с описанием из журнала
   (PR на каждый этап — решение пользователя, разрешение постоянное). Сливает пользователь,
   Claude — только по явной просьбе.

## Ветки

- `release-2` — интеграционная ветка 2.0: только слитые PR этапов, прямых коммитов нет.
  Это **базовая ветка** работы вместо `main`.
- `rails-integration` — рабочая ветка сессий. **После слияния PR этапа пересоздавай её от
  `release-2`, а не от `main`** (в `main` нет работы 2.0):
  ```bash
  git fetch origin release-2
  git checkout -B rails-integration origin/release-2
  git push --force-with-lease -u origin rails-integration
  ```
- `main` — релиз 1.x. В неё не пушим и PR не открываем до готовности 2.0 (финал: PR
  `release-2` → `main`, версия 2.0.0, тег `v2.0.0`). Исправления в `main` вливаются в `release-2`.

Справка: требования портала — `docs/rails_integration_requirements.md` (Т1–Т19), структура
реального архива и объёмы — `docs/gar_archive_structure.md`, форматы XML — `docs/xml_schema/*.xsd`,
правила адресной строки ФНС — `docs/Правила_формирования_адресной_строки.docx`.

## Команды

```bash
bin/setup_test_db                          # тестовый PostgreSQL на :6433 (без Docker; идемпотентно)
export PATH="$(ruby -e 'print Gem.bindir'):$PATH" LANG=C.UTF-8   # в облаке: бинарники гемов и UTF-8
bundle exec rspec                          # все тесты; :slow — с GAR_SLOW_TESTS=1
bundle exec rspec spec/integration         # сквозной конвейер на синтетическом архиве
bundle exec rubocop
python3 examples/tools/gar_toc.py <zip|URL> 43 11   # оглавление архива ГАР без распаковки
```

`TEST_DATABASE_URL` по умолчанию `postgresql://postgres:postgres@localhost:6433/gar_db_test`.

## Тесты

- Без тега — unit-тесты, работают без БД. Тег `:db` — БД подключается лениво, фикстуры
  (`Gar::TestSupport::Sample`) заливаются автоматически в схему `gar`.
- Свои схемы в `:db`-примерах — через `isolated_schema` / `register_schema_for_cleanup`
  (удаляются после примера). Конфигурация гема сбрасывается перед каждым примером.
- Синтетический архив с реальной структурой — `GarArchiveBuilder`; готовый связный набор
  (Киров 43, Коми 11, Москва 77, пустой 80) — `GarSampleArchive.build`.
- Проверяем публичное поведение и результат; моки — только на внешних границах (HTTP, время).
  Не тестируем приватные методы через `send` в новом коде.
- Известная ошибка, которую ещё не починили, — пример с `pending "Ошибка N: …"`.

## Соглашения

- Комментарии, сообщения логов и исключений — на русском.
- Ruby ≥ 3.3, `# frozen_string_literal: true`, двойные кавычки, rubocop из `.rubocop.yml`.
- В `lib/` никаких `puts`/`print`/`exit`: логгер `Gar.logger` и исключения гема (`Gar::Error`).
- Имена схем и таблиц в SQL — через `quote_ident`; значения — через параметры.
- Публичный API 2.0.0 можно ломать относительно 1.x — изменения фиксировать для CHANGELOG.
