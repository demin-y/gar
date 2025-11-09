#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Get all available GAR versions

require "gar"

puts "Получение всех доступных версий GAR"
puts "=" * 50

begin
  downloader = Gar::Downloader.new
  versions = downloader.all_versions

  puts "Найдено #{versions.length} версий"
  puts ""

  # Показать последние 5 версий в таблице
  puts "Последние версии:"
  puts "ID       Дата         Описание                                 Полная     Дельта    "
  puts "-" * 85

  versions.each do |version|
    id          = version["VersionId"].to_s
    date        = version["Date"] ? version["Date"].split("T").first : "N/A"
    description = version["TextVersion"] || "N/A"
    full_base   = version["GarXMLFullURL"] ? "✓" : "✗"
    delta       = version["GarXMLDeltaURL"] ? "✓" : "✗"

    # Обрезаем описание
    description = "#{description[0..35]}..." if description.length > 38

    puts format("%-8<id>s %-12<date>s %-40<description>s %-10<full_base>s %-10<delta>s", id:, date:, description:, full_base:, delta:)
  end
rescue StandardError => e
  puts "Ошибка: #{e.message}"
end
