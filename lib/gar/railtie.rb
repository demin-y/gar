# frozen_string_literal: true

require "rails/railtie"

module Gar
  # Подключение к Rails (Т15): rake-задачи gar:* и генератор rails g gar:install
  # (config/initializers/gar.rb). Логгер приложения гем берёт сам (Configuration#logger)
  class Railtie < Rails::Railtie
    rake_tasks { load File.expand_path("tasks/gar.rake", __dir__) }
  end
end
