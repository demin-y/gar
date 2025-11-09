# frozen_string_literal: true

source "https://rubygems.org"

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

# Specify your gem's dependencies in gar.gemspec
gemspec

group :development do
  gem "benchmark",            "~> 0.2"
  gem "lefthook",             "~> 1.6"
  gem "rake",                 "~> 13.0"
  gem "rspec",                "~> 3.12"
  gem "rubocop",              "~> 1.82.1"
  gem "rubocop-performance",  "~> 1.0"
  gem "rubocop-rspec",        "~> 2.0"
  gem "webmock",              "~> 3.18"
  gem "yard",                 "~> 0.9"
end

group :test do
  gem "database_cleaner-active_record", "~> 2.1"
end
