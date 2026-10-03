#!/usr/bin/env ruby
# frozen_string_literal: true

# Качество автодополнения на типичных вводах: для каждого запроса из YAML — место ожидаемого
# адреса в выдаче Gar.autocomplete (по full_adm_path) и время:
#
#   GAR_DATABASE_URL=postgresql://… ruby examples/benchmarks/search_quality.rb [queries.yml] [--verbose]
#
# По умолчанию — examples/benchmarks/queries_43_11.yml (субъекты 43 и 11). Итог: доля запросов,
# где ожидаемый адрес первый (hit@1) и в первой тройке (hit@3), p50/p95 времени. --verbose
# печатает выдачу промахов. Код выхода 1, если есть запросы без ожидаемого адреса в первой тройке.

require "bundler/setup"
require "gar"
require "yaml"

MARKS   = { 1 => "✓", 2 => "2", 3 => "3" }.freeze
verbose = ARGV.delete("--verbose")
file    = ARGV[0] || File.join(__dir__, "queries_43_11.yml")
queries = YAML.safe_load_file(file, symbolize_names: true)
Gar.configuration.logger = Logger.new($stderr, level: :warn)

results =
  queries.map do |item|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    found   = Gar.autocomplete(item[:query], limit: 10)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    { **item, found:, elapsed:, place: found.index { _1.address == item[:expect] }&.+(1) }
  end

results.each do |result|
  mark = MARKS.fetch(result[:place], "✗")
  puts format("%<mark>s %<ms>6.1f мс  %<query>-40s %<place>s", mark:, ms: result[:elapsed] * 1000, query: result[:query],
                                                                  place: result[:place] ? "" : "→ #{result[:found].first&.address || 'пусто'}")
  result[:found].first(5).each { puts "            #{_1.address || _1.name}" } if verbose && result[:place] != 1
end

times = results.map { _1[:elapsed] * 1000 }.sort
share = ->(limit) { results.count { _1[:place] && _1[:place] <= limit } * 100.0 / results.size }
puts format("hit@1 %<hit1>.0f %%, hit@3 %<hit3>.0f %% из %<count>d; p50 %<p50>.1f мс, p95 %<p95>.1f мс",
            hit1: share.call(1), hit3: share.call(3), count: results.size, p50: times[times.size / 2], p95: times[(times.size * 0.95).floor])
exit(results.all? { _1[:place] && _1[:place] <= 3 } ? 0 : 1)
