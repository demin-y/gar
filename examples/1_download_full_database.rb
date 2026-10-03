#!/usr/bin/env ruby
# frozen_string_literal: true

# Скачивание последней выгрузки ГАР (Gar.download). С субъектами — только их файлы и справочники
# (HTTP Range, два субъекта — ~300 МБ), без них — весь архив (~50 ГБ):
#
#   GAR_REGIONS=43,11 bundle exec ruby examples/1_download_full_database.rb [version_id]

require_relative "example_helper"

regions = Gar.configuration.region_codes
abort "Без GAR_REGIONS качается весь архив (~50 ГБ): задайте субъекты или GAR_FULL=1" if regions.empty? && !ENV["GAR_FULL"]

latest = Gar::Downloader.new.latest_version
puts "Последняя выгрузка: #{latest['VersionId']} (#{latest['TextVersion']})"
puts "Субъекты: #{regions.empty? ? 'вся страна' : regions.join(', ')}"

zip = Gar.download(ARGV[0]&.then { Integer(_1) }, on_progress: progress)
puts "Архив: #{zip} (#{Gar::Utils.format_size(File.size(zip))})"
puts "Дальше: GAR_REGIONS=#{regions.join(',')} bundle exec ruby examples/2_import_full_base.rb"
