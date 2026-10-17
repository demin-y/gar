# frozen_string_literal: true

# Rake-задачи гема (Т15). В Rails их подключает Gar::Railtie, настройки — из
# config/initializers/gar.rb. Без Rails: load "gar/tasks/gar.rake" в Rakefile после Gar.configure.
# В zsh аргументы — в кавычках: rake "gar:import[43,11]".
require "gar"

namespace :gar do
  # В Rails задачам нужно окружение приложения (инициализатор гема, логгер)
  task :environment do
    Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
  end

  desc "Скачать полную выгрузку ГАР (по умолчанию последнюю) в config.full_base_dir"
  task :download, [:version_id] => :environment do |_task, args|
    Gar::Tasks.new.download(args[:version_id])
  end

  desc "Загрузить скачанный архив в новую схему: gar:import[43,11] — субъекты, без них — config.region_codes"
  task import: :environment do |_task, args|
    Gar::Tasks.new.import(args.extras)
  end

  desc "Построить пути схемы (по умолчанию текущей): gar:build_paths[gar_v20260116]"
  task :build_paths, [:schema] => :environment do |_task, args|
    Gar::Tasks.new.build_paths(args[:schema])
  end

  desc "Сделать готовую схему текущей: gar:switch[gar_v20260116]"
  task :switch, [:schema] => :environment do |_task, args|
    Gar::Tasks.new.switch(args[:schema])
  end

  desc "Обновить ГАР до последней выгрузки: дельты или полный импорт (для крона)"
  task update: :environment do
    Gar::Tasks.new.update
  end

  desc "Версия, статус и размер текущей, резервных и загружаемых схем"
  task status: :environment do
    Gar::Tasks.new.status
  end

  desc "Удалить лишние резервные схемы и схемы импорта, которые уже не станут текущими"
  task cleanup: :environment do
    Gar::Tasks.new.cleanup
  end
end
