#!/usr/bin/env ruby
# frozen_string_literal: true

# Скачивание последней выгрузки ГАР (Gar.download). С субъектами — только их файлы и справочники
# (HTTP Range, два субъекта — ~300 МБ), без них — весь архив (~50 ГБ):
#
#   GAR_REGIONS=43,11 bundle exec ruby examples/1_download_full_database.rb [version_id]

require_relative "example_helper"

regions = Gar.configuration.region_codes
abort "Без GAR_REGIONS качается весь архив (~50 ГБ): задайте субъекты или GAR_FULL=1" if regions.empty? && !ENV["GAR_FULL"]

# То же, что Gar.download(version_id), но сведения о выгрузке видны до скачивания
downloader = Gar::Downloader.new
info       = version_from_argv(downloader)
puts "Выгрузка #{info['VersionId']} (#{info['TextVersion']}), субъекты: #{regions.empty? ? 'вся страна' : regions.join(', ')}"

zip = downloader.download_full_base(info, region_codes: regions, on_progress: progress)
puts "Архив: #{zip} (#{Gar::Utils.format_size(File.size(zip))})"
puts "Дальше: #{"GAR_REGIONS=#{regions.join(',')} " if regions.any?}bundle exec ruby examples/2_import_full_base.rb"
