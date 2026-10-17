# frozen_string_literal: true

module Gar
  # Общий ход Gar.update! одной шкалой 0..SCALE (Т34, on_overall_progress): стадии сообщают ход
  # в своих единицах — байты архива, байты XML, записи путей, — а приложению нужна одна полоса.
  # План обновления — шаги [стадия, вес] по порядку: полный импорт — FULL, дельты — DELTA на
  # каждую версию цепочки. Ход стадии — доля веса её шага; назад полоса не идёт (докачка после
  # обрыва начинает стадию заново), одно и то же значение не повторяется. Последние TAIL — только
  # у finish: после стадий ещё очистка схем и архивов, и упавшая очистка не покажет SCALE
  class Progress
    SCALE = 1000
    TAIL  = 10
    # Веса — ориентир по замерам частичной загрузки субъектов 43 и 11 (README, «Скорость и
    # качество»): скачивание ≈1 мин, загрузка XML ≈45 с, индексы ≈10 с, пути ≈50 с. Дельта —
    # скачивание, разбор XML во временные таблицы, слияние с пересборкой путей
    FULL  = [[:download, 30], [:import, 30], [:indexes, 10], [:paths, 28], [:switch, 2]].freeze
    DELTA = [[:download, 30], [:delta, 35], [:merge, 35]].freeze

    # on_progress — ->(done, total, stage) стадий, как прежде; on_overall — ->(done, SCALE)
    def initialize(on_progress, on_overall)
      @on_progress = on_progress
      @on_overall  = on_overall
      @steps       = []
      @step        = 0
      @reported    = -1
    end

    # Шаги [стадия, вес] → [стадия, начало, конец] на шкале
    def plan(steps)
      unit   = (SCALE - TAIL) / steps.sum(&:last).to_f
      ends   = 0.0
      @steps = steps.map { |stage, weight| [stage, ends, ends += weight * unit] }
    end

    # Стадия, которой нет в плане дальше текущего шага, на общую полосу не влияет; без total
    # (сервер не сообщил размер) шаг только начинается
    def call(done, total, stage)
      @on_progress&.call(done, total, stage)
      return unless @on_overall

      index = (@step...@steps.size).find { @steps[_1].first == stage } or return
      @step = index
      _, from, to = @steps[index]
      fraction = total&.positive? ? done.clamp(0, total).fdiv(total) : 0
      report((from + ((to - from) * fraction)).floor)
    end

    def finish = report(SCALE)

    private

    def report(value)
      return unless @on_overall && value > @reported

      @reported = value
      @on_overall.call(value, SCALE)
    end
  end
end
