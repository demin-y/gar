# frozen_string_literal: true

require_relative "lib/gar/version"

Gem::Specification.new do |spec|
  spec.name          = "gar"
  spec.version       = Gar::VERSION
  spec.platform      = Gem::Platform::RUBY
  spec.authors       = ["Yuri Demin"]
  spec.email         = ["demin.y.87@gmail.com"]

  spec.summary       = "Russian State Address Register (GAR/FIAS) in PostgreSQL: import, delta updates and address search"
  spec.description   = "Downloads selected regions of the GAR (FIAS) export from the Federal Tax Service, imports them " \
                       "into PostgreSQL, keeps the database current with deltas, and provides address autocomplete, " \
                       "address lookup by GUID and matching of legacy addresses. Designed to run inside a Rails app."
  spec.homepage      = "https://github.com/demin-y/gar-ruby"
  spec.license       = "MIT"

  spec.metadata["source_code_uri"]   = spec.homepage
  spec.metadata["changelog_uri"]     = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]   = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob(["lib/**/*", "CHANGELOG.md", "LICENSE.txt", "README.md", "gar.gemspec"])

  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.3"

  spec.add_dependency "connection_pool", ">= 2.5", "< 4"
  spec.add_dependency "logger",          "~> 1.5"
  spec.add_dependency "ox",              "~> 2.14"
  spec.add_dependency "parallel",        "~> 1.26"
  spec.add_dependency "pg",              "~> 1.2"
  spec.add_dependency "rubyzip",         "~> 3.0"
end
