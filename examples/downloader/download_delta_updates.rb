#!/usr/bin/env ruby
# frozen_string_literal: true

# Скачивание дельты выгрузки (по умолчанию последней) в config.delta_dir. Применяет дельты к
# базе Gar.update! (examples/6_update.rb) — по порядку версий и с проверкой цепочки; вручную —
# Gar::Delta.new.apply(zip).
#
#   bundle exec ruby examples/downloader/download_delta_updates.rb [20261002]

require_relative "../example_helper"

downloader = Gar::Downloader.new
info = version_from_argv(downloader)
abort "У выгрузки #{info['VersionId']} нет дельты" if info["GarXMLDeltaURL"].to_s.empty?

zip = downloader.download_delta(info, on_progress: progress)
puts "Дельта: #{zip} (#{Gar::Utils.format_size(File.size(zip))})"
