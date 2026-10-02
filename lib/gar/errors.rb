# frozen_string_literal: true

module Gar
  # Базовая ошибка гема: приложению достаточно ловить её
  class Error < StandardError; end

  # Неверная настройка гема
  class ConfigurationError < Error; end

  # Ошибка загрузки архива с сайта ФНС
  class DownloadError < Error; end

  # Ошибка импорта архива в базу
  class ImportError < Error; end
end
