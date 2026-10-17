# frozen_string_literal: true

require "open3"
require "rbconfig"

# Т21: каждая публичная константа результатов подгружается сама — в свежем процессе она первая,
# к которой обращаются, и gar/results.rb до неё не загружен
RSpec.describe "autoload результатов" do
  # Константы gar/results.rb — по месту определения (в процессе rspec файл загружаем сами)
  let(:constants) do
    require "gar/results"
    Gar.constants.select { Gar.const_source_location(_1)&.first&.end_with?("/gar/results.rb") }
  end

  it "находит константы gar/results.rb" do
    expect(constants).to include(:Serializable, :Address, :AddressElement, :HouseElement, :HouseAddition)
  end

  it "каждая подгружается первым обращением в новом процессе" do
    # Один процесс загружает гем, на каждую константу — свой fork, где gar/results.rb ещё не загружен
    script = <<~RUBY
      require "gar"
      failed = ARGV.reject { |name| Process.wait2(fork { Gar.const_get(name, false) })[1].success? }
      abort("не подгрузились: \#{failed.join(', ')}") if failed.any?
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script, *constants.map(&:to_s))

    expect(status).to be_success, output
  end
end
