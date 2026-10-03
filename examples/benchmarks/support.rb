# frozen_string_literal: true

# Общее для замеров examples/benchmarks: время блока и процентили выборки
module Benchmarks
  module_function

  # Время блока, с
  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  # Процентили выборки samples (с) в мс: { p50:, p95:, max: }
  def percentiles(samples)
    sorted = samples.sort
    at     = ->(share) { sorted[((sorted.size - 1) * share).round] * 1000 }
    { p50: at.call(0.5), p95: at.call(0.95), max: sorted.last * 1000 }
  end
end
