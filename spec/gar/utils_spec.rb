# frozen_string_literal: true

RSpec.describe Gar::Utils do
  describe ".format_size" do
    it "выбирает единицу по размеру" do
      expect([0, 512, 1536, 2 * (1024**2), 49 * (1024**3)].map { described_class.format_size(_1) })
        .to eq(["0 Б", "512 Б", "1.5 КБ", "2.0 МБ", "49.0 ГБ"])
    end
  end
end
