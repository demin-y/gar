# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |_task|
  ENV["INTEGRATION_TESTS"] = "true"
end

task default: :spec

# Задачи gar:* на копии репозитория: bundle exec rake "gar:import[43,11]" (настройки — из ENV)
load File.expand_path("lib/gar/tasks/gar.rake", __dir__)
