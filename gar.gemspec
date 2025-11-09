# frozen_string_literal: true

require_relative "lib/gar/version"

Gem::Specification.new do |spec|
  spec.name          = "gar"
  spec.version       = Gar::VERSION
  spec.platform      = Gem::Platform::RUBY
  spec.authors       = ["Yuri Demin"]
  spec.email         = ["demin.y.87@gmail.com"]

  spec.summary       = "Ruby gem for working with Russian State Address Register (GAR)"
  spec.description   = "Gem provides functionality to download, parse and work with GAR (State Address Register) data including address search and validation."
  spec.homepage      = "https://github.com/demin-y/gar"
  spec.license       = "MIT"

  spec.metadata["homepage_uri"]      = spec.homepage
  spec.metadata["source_code_uri"]   = spec.homepage
  spec.metadata["bug_tracker_uri"]   = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob(["lib/**/*", "LICENSE.txt", "README.md", "gar.gemspec"])

  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.1"

  spec.add_dependency "httparty", "~> 0.21"
  spec.add_dependency "logger",   "~> 1.5"
  spec.add_dependency "mini_sql", "~> 1.6"
  spec.add_dependency "ox",       "~> 2.14"
  spec.add_dependency "parallel", "~> 1.26"
  spec.add_dependency "pg",       "~> 1.2"
  spec.add_dependency "rubyzip",  "~> 2.3"
end
