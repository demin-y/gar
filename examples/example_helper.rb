# frozen_string_literal: true

# Общая настройка скриптов examples/: гем из репозитория и настройки из переменных окружения.
#
#   GAR_DATABASE_URL — база ГАР (обязательна для импорта, путей, переключения и поиска)
#   GAR_REGIONS      — субъекты через запятую: «43,11»; без неё — вся страна
#   GAR_DOWNLOADS    — каталог архивов (по умолчанию ./downloads)
#   GAR_CA_FILE      — свой сертификат УЦ (корпоративный прокси), если его нет в хранилище ОС

require "bundler/setup"
require "gar"

Gar.configure do |config|
  config.region_codes  = ENV.fetch("GAR_REGIONS", "").split(",")
  config.full_base_dir = File.join(ENV.fetch("GAR_DOWNLOADS", "downloads"), "full_base")
  config.delta_dir     = File.join(ENV.fetch("GAR_DOWNLOADS", "downloads"), "delta")
  config.api_ca_file   = ENV["GAR_CA_FILE"] if ENV["GAR_CA_FILE"]
  config.logger        = Logger.new($stderr, level: :warn)
end

STAGES = { download: "Скачивание", import: "Импорт", indexes: "Индексы", paths: "Пути", switch: "Переключение", delta: "Дельта" }.freeze

# on_progress для шагов загрузки: строка стадии с процентом, перерисовывается на месте
def progress
  lambda do |done, total, stage|
    percent = total.to_i.positive? ? " #{done * 100 / total}%" : " #{Gar::Utils.format_size(done)}"
    print "\r#{STAGES.fetch(stage, stage)}:#{percent}   "
    puts if total && done >= total
  end
end
