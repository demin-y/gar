#!/usr/bin/env ruby
# frozen_string_literal: true

# Проверка доступа к API и файловому серверу ФНС с этой машины: список выгрузок, последняя
# выгрузка и поддержка частичной загрузки (HTTP Range). Ошибка SSL — сеть подменяет сертификат
# (корпоративный прокси) или ФНС сменила УЦ: укажите файл сертификата в GAR_CA_FILE
# (config.api_ca_file), а не отключайте проверку.
#
#   bundle exec ruby examples/check_api.rb

require_relative "example_helper"

begin
  downloader = Gar::Downloader.new
  versions   = downloader.all_versions.sort_by { _1["VersionId"] }
  puts "API: #{versions.size} выгрузок, с #{versions.first['VersionId']} по #{versions.last['VersionId']}"

  uri  = URI(versions.last["GarXMLFullURL"])
  head = Net::HTTP.start(uri.host, uri.port, use_ssl: true, ca_file: Gar.configuration.api_ca_file) { _1.head(uri.path) }
  puts "Файловый сервер: #{head.code}, архив #{Gar::Utils.format_size(head.content_length)}, Range: #{head['Accept-Ranges'] == 'bytes' ? 'есть' : 'нет'}"
rescue Gar::Error, OpenSSL::SSL::SSLError => e
  # Ошибку SSL API загрузчик повторяет и отдаёт как Gar::DownloadError с её текстом
  abort "Ошибка: #{e.message}#{"\nСертификат не проверен: укажите сертификат УЦ в GAR_CA_FILE" if e.message.include?('SSL')}"
end
