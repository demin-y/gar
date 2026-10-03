#!/usr/bin/env ruby
# frozen_string_literal: true

# Сведения о выгрузке по версии (по умолчанию — последней)
#
#   bundle exec ruby examples/downloader/get_version_by_id.rb [20261002]

require_relative "../example_helper"

downloader = Gar::Downloader.new
begin
  info = ARGV[0] ? downloader.version_info(Integer(ARGV[0])) : downloader.latest_version
rescue Gar::DownloadError => e
  abort "Ошибка: #{e.message}"
end
info.each { |key, value| puts format("%<key>-20s %<value>s", key:, value:) unless value.to_s.empty? }
