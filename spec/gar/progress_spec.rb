# frozen_string_literal: true

RSpec.describe Gar::Progress do
  def run(steps, events)
    stages  = []
    overall = []
    progress = described_class.new(->(*args) { stages << args }, ->(done, total) { overall << [done, total] })
    progress.plan(steps)
    events.each { progress.call(*_1) }
    progress.finish
    [stages, overall]
  end

  it "кладёт стадии плана на одну шкалу по весам, последние TAIL — только у finish, ход стадий передаёт как есть" do
    stages, overall = run([[:download, 1], [:import, 3]],
                          [[0, 100, :download], [100, 100, :download], [0, 10, :import], [5, 10, :import], [10, 10, :import]])

    expect(stages).to eq([[0, 100, :download], [100, 100, :download], [0, 10, :import], [5, 10, :import], [10, 10, :import]])
    expect(overall).to eq([[0, 1000], [247, 1000], [618, 1000], [990, 1000], [1000, 1000]])
  end

  it "повторы стадии в плане — шаги по порядку: цепочка дельт идёт вперёд, а не по кругу" do
    _, overall = run([[:download, 1], [:delta, 1]] * 2,
                     [[1, 1, :download], [1, 1, :delta], [0, 1, :download], [1, 1, :download], [1, 1, :delta]])

    expect(overall.map(&:first)).to eq([247, 495, 742, 990, 1000])
  end

  it "назад не идёт: докачка с начала и стадия вне плана полосу не двигают" do
    _, overall = run([[:download, 1], [:paths, 1]],
                     [[50, 100, :download], [0, 100, :download], [7, 9, :switch], [1, 2, :paths], [100, 100, :download]])

    expect(overall.map(&:first)).to eq([247, 742, 1000])
  end

  it "без плана (обновлять нечего) доходит до конца" do
    _, overall = run([], [[1, 1, :download]])

    expect(overall).to eq([[1000, 1000]])
  end

  it "стадия без total (размер неизвестен) только начинает свой шаг" do
    _, overall = run([[:download, 1], [:import, 1]], [[5, nil, :download], [0, 0, :import]])

    expect(overall.map(&:first)).to eq([0, 495, 1000])
  end

  it "без общей полосы только передаёт стадии" do
    stages   = []
    progress = described_class.new(->(*args) { stages << args }, nil)
    progress.plan(described_class::FULL)
    progress.call(1, 2, :import)
    progress.finish

    expect(stages).to eq([[1, 2, :import]])
  end
end
