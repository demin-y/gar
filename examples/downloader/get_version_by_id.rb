#!/usr/bin/env ruby
# frozen_string_literal: true

# Сведения о выгрузке по версии (по умолчанию — последней): версия, описание, ссылки на архивы
#
#   bundle exec ruby examples/downloader/get_version_by_id.rb [20261002]

require_relative "../example_helper"

info = version_from_argv(Gar::Downloader.new)
info.each { |key, value| puts format("%<key>-20s %<value>s", key:, value:) unless value.to_s.empty? }
