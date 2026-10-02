# Примеры использования гема GAR

Эта папка содержит примеры скриптов для демонстрации различных функций гема GAR, организованные по компонентам.
Все скрипты игнорируются Git и предназначены только для локального тестирования и экспериментов.

## Структура папок

```
examples/
├── downloader/                  # Примеры работы с загрузчиком данных
│   ├── get_all_versions.rb
│   ├── get_latest_version.rb
│   ├── get_version_info.rb
│   ├── download_full_base.rb
│   ├── download_delta.rb
│   └── cleanup_old_files.rb
├── search.rb                    # Примеры низкоуровневой работы с адресами
├── configure_download_paths.rb  # Настройка путей загрузки
└── README.md                    # Эта документация
```

## Компонент: Downloader (Загрузчик)

Примеры работы с `Gar::Downloader` для получения информации о версиях и загрузки данных.

### get_all_versions.rb
Получение списка всех доступных версий данных GAR.

```bash
./examples/downloader/get_all_versions.rb
```

### get_latest_version.rb
Получение информации о последней версии.

```bash
./examples/downloader/get_latest_version.rb
```

### get_version_info.rb
Получение детальной информации о конкретной версии.

```bash
./examples/downloader/get_version_info.rb
```

### download_full_base.rb
Пример загрузки полной базы данных с поддержкой возобновления и версионными именами файлов (закомментирован для безопасности).

```bash
./examples/downloader/download_full_base.rb
```

### download_delta.rb
Пример загрузки дельта обновлений (закомментирован для безопасности).

```bash
./examples/downloader/download_delta.rb
```

### cleanup_old_files.rb
Пример очистки старых ZIP файлов для освобождения дискового пространства.

```bash
./examples/downloader/cleanup_old_files.rb
```

## Компонент: PathBuilder

### 3_populate_full_paths.rb
Заполнение `full_adm_path` и `full_mun_path` (и их `tsvector`) у адресных объектов и домов
в импортированной схеме. Прерванное построение продолжается повторным запуском.

```bash
make dev-db-up
./examples/3_populate_full_paths.rb [схема]
```

## Компонент: Address (Низкоуровневые операции)

Примеры прямого использования класса `Gar::Address` для продвинутых сценариев.

### find.rb
Прямое использование метода поиска адресов.

```bash
./examples/address/find.rb
```

## Общие скрипты

### get_versions.rb
Удобный скрипт для быстрого просмотра доступных версий в табличном виде.

```bash
./examples/get_versions.rb
```

### test_basic.rb
Комплексное тестирование всего функционала гема.

```bash
./examples/test_basic.rb
```

## Быстрый старт

1. **Установка зависимостей:**
   ```bash
   make install
   ```

2. **Исправление SSL проблем (если возникают ошибки сертификатов):**
   ```bash
   ./examples/fix_ssl.rb
   ```

3. **Запуск базы данных (для некоторых примеров):**
   ```bash
   make db-start
   ```

4. **Запуск примеров:**
   ```bash
   # Просмотр версий
   ./examples/get_versions.rb

   # Тестирование функционала
   ./examples/test_basic.rb

   # Загрузка данных (примеры)
   ./examples/downloader/get_latest_version.rb
   ```

## Конфигурация

### Настройка путей загрузки и сохранения

Гем поддерживает настройку пользовательских URL для API и директорий для сохранения файлов:

```bash
./examples/configure_download_paths.rb
```

```ruby
# Полная настройка в коде
Gar.configure do |config|
  # URL для API запросов
  config.full_base_url = "https://my-fias-proxy.com/api"
  config.delta_url = "https://my-delta-server.com/api"

  # Директории для сохранения скачанных файлов
  config.full_base_dir = "./downloads/full_base"
  config.delta_dir = "./downloads/delta"

  # SSL верификация (отключить при проблемах с сертификатами)
  config.ssl_verify = false
end
```

### Настройки по умолчанию:

**URL для API:**
- Полная база: `https://fias.nalog.ru/WebServices/Public`
- Дельта: `https://fias.nalog.ru/WebServices/Public`

**Директории для файлов:**
- Полная база: `./downloads/full_base`
- Дельта: `./downloads/delta`

**SSL настройки:**
- Верификация SSL: `true` (включена)

**Настройки повторных попыток:**
- Количество попыток: `3`
- Таймаут между попытками: `5` сек

Директории создаются автоматически при первой загрузке файлов.

## Примечания

- **Безопасность:** Реальные загрузки данных закомментированы для предотвращения случайных скачиваний
- **База данных:** Многие скрипты требуют запущенной PostgreSQL базы данных
- **Размеры:** Загрузка полной базы GAR может требовать несколько гигабайт места
- **Время:** Импорт данных может занимать от минут до часов
