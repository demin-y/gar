# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |_task|
  ENV["INTEGRATION_TESTS"] = "true"
end

task default: :spec
