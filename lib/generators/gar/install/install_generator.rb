# frozen_string_literal: true

require "rails/generators"

module Gar
  module Generators
    # rails g gar:install — инициализатор config/initializers/gar.rb со всеми настройками гема
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Создаёт config/initializers/gar.rb с настройками гема gar"

      def create_initializer = copy_file("gar.rb", "config/initializers/gar.rb")
    end
  end
end
