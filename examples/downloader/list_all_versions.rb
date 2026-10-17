#!/usr/bin/env ruby
# frozen_string_literal: true

# Все выгрузки, которые есть на сервере ФНС (около 8 месяцев): версия, полный архив, дельта
#
#   bundle exec ruby examples/downloader/list_all_versions.rb

require_relative "../example_helper"

versions = Gar::Downloader.new.all_versions.sort_by { _1["VersionId"] }
puts "Выгрузок: #{versions.size}"
versions.each do |version|
  full  = version["GarXMLFullURL"].to_s.empty? ? "—" : "полная"
  delta = version["GarXMLDeltaURL"].to_s.empty? ? "—" : "дельта"
  puts format("%<id>-10s %<full>-7s %<delta>-7s %<text>s", id: version["VersionId"], full:, delta:, text: version["TextVersion"])
end
