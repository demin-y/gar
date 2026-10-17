#!/usr/bin/env ruby
# frozen_string_literal: true

# Удаление старых архивов из config.full_base_dir: оставить keep_versions последних версий и
# файлы моложе keep_days дней. По умолчанию — только показать (dry run); удалить — --delete.
# Gar.update! сам удаляет применённые дельты и архивы старее загруженного (config.cleanup_downloads).
#
#   bundle exec ruby examples/downloader/cleanup_old_files.rb [--delete]

require_relative "../example_helper"

Gar.configuration.logger = Logger.new($stdout, level: :info)
delete  = ARGV.include?("--delete")
removed = Gar::Downloader.new.cleanup_old_files(keep_versions: 2, keep_days: 30, dry_run: !delete)
verb    = delete ? "Удалено" : "Будет удалено"
puts removed.empty? ? "Удалять нечего" : "#{verb}: #{removed.size}"
