# frozen_string_literal: true

RSpec.describe Gar::Synonyms do
  describe ".words" do
    it "приводит регистр и ё, убирает точки и знаки, сохраняя дефис и дробь" do
      expect(described_class.words("Просп. Ёлкина, д.10/2 (пр-кт)")).to eq(["просп", "елкина", "д", "10/2", "пр-кт"])
    end
  end

  describe "#tsquery" do
    let(:synonyms) { described_class.new([["проспект", "пр", "просп"], ["большая", "б"], ["бульвар", "б"], ["корпус", "к"]], stopwords: ["к"]) }

    it "разворачивает каждое слово в OR вариантов его групп; последнее слово при prefix — префикс, синонимы — целиком" do
      expect(synonyms.tsquery(["б", "садо"], prefix: true)).to eq("('б' | 'большая' | 'бульвар') & ('садо':*)")
      expect(synonyms.tsquery(["просп"])).to eq("('просп' | 'проспект' | 'пр')")
    end

    it "пропускает слово, среди вариантов которого есть стоп-слово, и возвращает nil без слов" do
      expect(synonyms.tsquery(["ленина", "к", "2"])).to eq("('ленина') & ('2')")
      expect(synonyms.tsquery(["к"])).to be_nil
    end

    it "вариант из нескольких слов ищет фразой" do
      expect(described_class.new([["пгт", "поселок городского типа"]]).tsquery(["пгт"])).to eq("('пгт' | 'поселок' <-> 'городского' <-> 'типа')")
    end
  end

  describe ".for", :db do
    it "собирает группы из справочников схемы, встроенного словаря и config.synonyms" do
      Gar.configuration.synonyms = { "проспект" => ["прсп"] }
      synonyms = described_class.for("gar", db_connection)

      expect(synonyms.variants("ул")).to include("улица")
      expect(synonyms.variants("пр-кт")).to include("проспект")
      expect(synonyms.variants("проспект")).to include("просп", "прсп")
      expect(synonyms.tsquery(["к", "2"])).to eq("('2')")
    end

    it "без встроенного словаря берёт только справочники и настройку" do
      Gar.configuration.builtin_synonyms = false

      expect(described_class.for("gar", db_connection).variants("просп")).to eq(["просп"])
    end
  end
end
