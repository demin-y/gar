# Примеры гема GAR

Скриптам, которые работают с базой, нужен адрес базы ГАР в `GAR_DATABASE_URL` (гем не читает
`DATABASE_URL`): `make dev-db-up && export GAR_DATABASE_URL=postgresql://postgres:postgres@localhost:6432/gar_db_dev`.
Запуск из корня репозитория: `bundle exec ruby examples/<скрипт>.rb`.

В Rails те же шаги выполняют rake-задачи `gar:*` (README, раздел «Rails»).

## Загрузка базы по шагам

| Скрипт | Что делает |
|---|---|
| `1_download_full_database.rb` | скачивает последнюю полную выгрузку в `config.full_base_dir` (≈ 49 ГБ) |
| `2_import_full_base.rb` | загружает субъекты 43 и 11 из скачанного архива в схему `gar_v<версия>` |
| `3_populate_full_paths.rb [схема]` | строит пути схемы — нужны полнотекстовому поиску |
| `4_switch_to_imported_schema.rb [схема]` | делает готовую схему текущей |
| `5_search.rb` | примеры поиска `Gar::Search` |

## Rails

| Файл | Что показывает |
|---|---|
| `active_job_import.rb` | первая загрузка фоновой задачей с прогрессом на пульте |
| `active_job_update.rb` | обновление дельтами по расписанию Solid Queue |

## Загрузчик (`downloader/`)

| Скрипт | Что делает |
|---|---|
| `show_latest_version.rb` | последняя выгрузка ФНС и ссылки на архивы |
| `list_all_versions.rb` | все выгрузки: версия, дата, есть ли полный архив и дельта |
| `get_version_by_id.rb` | сведения о выгрузке по `VersionId` |
| `download_delta_updates.rb` | скачивает дельту последней выгрузки в `config.delta_dir` |
| `cleanup_old_files.rb` | удаляет старые архивы (сначала `dry_run`) |
| `../fix_ssl.rb` | проверка API ФНС без проверки сертификата |

## Прочее

| Файл | Что делает |
|---|---|
| `verify_fias_guids.rb streets.csv` | сверяет GUID улиц ФИАС со схемой ГАР (README, «Перенос старых адресов») |
| `benchmarks/generate_archive.rb`, `benchmarks/import_and_search.rb` | синтетический архив и замер импорта и поиска |
| `tools/gar_toc.py <zip или URL> 43 11` | оглавление архива ГАР без скачивания целиком (HTTP Range) |
| `tools/gar_delta_probe.py` | оглавление и примеры записей последних дельт ГАР |
