# Чек-лист проверки на реальных данных

Гем проверен на синтетическом архиве с реальной структурой (`GarSampleArchive`,
`generate_archive.rb`). Этот чек-лист — прогон на настоящей выгрузке ФНС для двух субъектов
портала (43, 11). Результаты (вывод команд) пришлите в тред проекта: по ним заполняются
таблица «Объёмы» в README и решения, отложенные до реальных данных.

Нужны: PostgreSQL 16+ (лучше 18, как у портала), свободные ≈ 60 ГБ на диске под архив и ≈ 20 ГБ
под базу (точнее станет известно из п. 2), `GAR_DATABASE_URL` с правами импортёра
(README, «Пользователи базы»).

Команды — rake-задачи гема (`bundle exec rake -T gar`) из копии репозитория; в приложении то
же самое — `bin/rails gar:…`.

```bash
export GAR_DATABASE_URL=postgresql://gar_importer:…@localhost/gar_db
cd путь/к/гему && bundle install
```

## 1. Скачивание и импорт

```bash
time bundle exec rake gar:download
time bundle exec rake "gar:import[43,11]"
```

- [ ] Время скачивания и импорта (вывод `time`, строки «Импорт … записей» из лога).
- [ ] Пиковая память процесса импорта (`/usr/bin/time -v` на Linux, `-l` на macOS).

## 2. Пути и размер базы

```bash
time bundle exec rake "gar:build_paths[gar_v<версия>]"
bundle exec rake "gar:switch[gar_v<версия>]" gar:status
psql "$GAR_DATABASE_URL" -c "SELECT relname, n_live_tup, pg_size_pretty(pg_total_relation_size(relid)) FROM pg_stat_user_tables WHERE schemaname = 'gar' ORDER BY pg_total_relation_size(relid) DESC"
```

- [ ] Время `build_paths` (запись в журнале этапа 2, п. 17: рост таблиц от пакетного UPDATE).
- [ ] Размер схемы `gar` из `gar:status` и по таблицам — в таблицу «Объёмы» README.
- [ ] Выгода `prune_hierarchy`: строк в `adm_hierarchy`/`mun_hierarchy` (из запроса выше) и
      число строк в файлах `AS_ADM_HIERARCHY`/`AS_MUN_HIERARCHY` субъектов (лог импорта).
- [ ] Размер индексов `adm_path_ids`/`mun_path_ids` (GIN):
      `SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) FROM pg_stat_user_indexes WHERE schemaname = 'gar' ORDER BY 2 DESC`.

## 3. Скорость поиска (цель — p95 < 100 мс)

```bash
bundle exec ruby examples/benchmarks/import_and_search.rb downloads/full_base/gar_xml_v<версия>.zip --schema gar --skip-import --queries 200
```

- [ ] Таблица p50/p95/max по видам запросов.

## 4. Адреса

- [ ] GUID улиц ФИАС из старой базы портала: `bundle exec ruby examples/verify_fias_guids.rb streets.csv > report.tsv` —
      сводка из stderr (сколько «совпадает», «другое название», «недействует», «не найден»).
- [ ] `Gar.match_house` по 5 881 адресу портала: сколько `:exact`, `:fuzzy`, `:none`, и 10–20
      примеров `:none` с альтернативами.
- [ ] `Gar.address(guid)` для 10–20 домов Кирова и Сыктывкара: `full_address` и `short_address`
      соответствуют правилам ФНС (`docs/Правила_формирования_адресной_строки.docx`).
- [ ] `Gar.autocomplete` на 10–20 типичных вводах операторов («Киров Ленина 10», «Сыктывкар
      Коммунистическая 3/1», «610000»): первым — ожидаемый адрес.

## 5. Дельты

Схема из п. 1–2 загружена из полной выгрузки версии V.

```bash
time bundle exec rake gar:update gar:status
```

- [ ] Время применения каждой дельты (лог «Дельта … применена») и что показал `gar:status`.
- [ ] Цепочка дельт против полного импорта той же версии: импортируйте полную выгрузку
      последней версии в другую схему (`Gar.import` с `config.database_schema = "gar_check"`)
      и сравните число записей и пути:
      `SELECT count(*) FROM gar.houses` и `SELECT count(*) FROM gar_check.houses`; адреса,
      которые есть в одной схеме и нет в другой:
      `SELECT full_adm_path FROM gar.houses EXCEPT SELECT full_adm_path FROM gar_check.houses LIMIT 20` (и наоборот).
- [ ] Перенос в иерархии: найдите в дельте объект с новым `PARENTOBJID` (вывод
      `examples/tools/gar_delta_probe.py`, «объектов с разным PATH») и проверьте путь его
      потомков после дельты.
- [ ] API ФНС: отвечает ли `https://fias.nalog.ru/WebServices/Public/GetAllDownloadFileInfo`
      с сервера портала. Если нет, а `fias-file.nalog.ru` доступен — нужен другой адрес API
      (`config.api_all_versions_url`) или список выгрузок без API (решение — после проверки).
