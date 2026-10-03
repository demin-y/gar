#!/usr/bin/env ruby
# frozen_string_literal: true

# Последняя выгрузка ФНС: версия, описание и ссылки на полный архив и дельту
#
#   bundle exec ruby examples/downloader/show_latest_version.rb

require_relative "../example_helper"

latest = Gar::Downloader.new.latest_version
puts "Версия:      #{latest['VersionId']} (#{latest['TextVersion']})"
puts "Полный архив: #{latest['GarXMLFullURL'].to_s.empty? ? 'нет' : latest['GarXMLFullURL']}"
puts "Дельта:       #{latest['GarXMLDeltaURL'].to_s.empty? ? 'нет' : latest['GarXMLDeltaURL']}"
