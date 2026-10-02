# frozen_string_literal: true

RSpec.describe Gar::Configuration do
  subject(:config) { described_class.new }

  def import_table_names = config.import_tables.map(&:name)

  describe "выбор загружаемых данных" do
    let(:dictionaries) { Gar::Schema::DICTIONARIES.map(&:name) }

    it "по умолчанию — минимальный набор: справочники, шесть таблиц субъекта, только актуальные записи" do
      expect(config).to have_attributes(preset: :minimal, hierarchies: [:adm, :mun], param_types: [5, 6, 7, 16, 22, 23],
                                        keep_history: false)
      expect(import_table_names).to eq(dictionaries + described_class::MINIMAL_TABLES)
    end

    it "набор :extended добавляет участки, помещения, реестр и хранит историю улиц" do
      config.preset = :extended

      expect(config.tables).to include(*described_class::MINIMAL_TABLES, :steads, :apartments, :rooms, :reestr_objects)
      expect(config.keep_history?(:address_objects)).to be(true)
      expect(config.keep_history?(:houses)).to be(false)
    end

    it "набор :full берёт все таблицы, все типы параметров и всю историю" do
      config.preset = "full"

      expect(import_table_names).to match_array(Gar::Schema::TABLES.keys)
      expect(config.param_types).to eq(:all)
      expect(config.keep_history?(:houses)).to be(true)
    end

    it "дополняет набор через tables +=, справочники грузит всегда" do
      config.tables += ["steads"]

      expect(import_table_names).to eq(dictionaries + described_class::MINIMAL_TABLES + [:steads])
    end

    it "исключает отключённые иерархии" do
      config.hierarchies = :adm

      expect(import_table_names).to include(:adm_hierarchy).and exclude(:mun_hierarchy)
    end

    it "настройки поверх набора не зависят от его значений" do
      config.param_types  = ["5", "7"]
      config.keep_history = ["houses"]

      expect(config.param_types).to eq([5, 7])
      expect(config.keep_history?(:houses)).to be(true)
      expect(config.keep_history?(:address_objects)).to be(false)
    end

    it "отвергает неизвестные значения ошибкой конфигурации" do
      expect { config.preset = :tiny }.to raise_error(Gar::ConfigurationError, /набор данных: :tiny/)
      expect { config.tables = [:houses, :params] }.to raise_error(Gar::ConfigurationError, /params/)
      expect { config.tables = [:house_types] }.to raise_error(Gar::ConfigurationError, /справочники грузятся всегда/)
      expect { config.hierarchies = [:adm, :geo] }.to raise_error(Gar::ConfigurationError, /geo/)
      expect { config.hierarchies = [] }.to raise_error(Gar::ConfigurationError, /хотя бы одна/)
    end
  end

  describe "Gar.reset_configuration!" do
    it "возвращает настройки по умолчанию" do
      Gar.configure { _1.preset = :full }

      Gar.reset_configuration!

      expect(Gar.configuration.preset).to eq(:minimal)
    end
  end
end
