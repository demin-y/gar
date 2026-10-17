# frozen_string_literal: true

RSpec.describe Gar::Configuration do
  subject(:config) { described_class.new }

  def import_table_names = config.import_tables.map(&:name)

  describe "выбор загружаемых данных" do
    let(:dictionaries) { Gar::Schema::DICTIONARIES.map(&:name) }

    it "по умолчанию — минимальный набор: справочники, шесть таблиц субъекта, только актуальные записи" do
      expect(config).to have_attributes(preset: :minimal, hierarchies: [:adm, :mun], param_types: [5, 6, 7, 16, 22, 23],
                                        keep_history: [], parallel_import_workers: [Etc.nprocessors, 4].min,
                                        import_maintenance_work_mem: nil)
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

    it "keep_history = true хранит историю всех таблиц, где она есть; nil возвращает значение набора" do
      config.keep_history = true
      expect(config.keep_history).to include(:address_objects, :houses, :adm_hierarchy, :house_params).and exclude(:reestr_objects)

      config.preset       = :extended
      config.keep_history = nil
      expect(config.keep_history).to eq([:address_objects])
    end

    it "отвергает неизвестные значения ошибкой конфигурации" do
      expect { config.preset = :tiny }.to raise_error(Gar::ConfigurationError, /набор данных: :tiny/)
      expect { config.tables = [:houses, :params] }.to raise_error(Gar::ConfigurationError, /params/)
      expect { config.tables = [:house_types] }.to raise_error(Gar::ConfigurationError, /справочники грузятся всегда/)
      expect { config.hierarchies = [:adm, :geo] }.to raise_error(Gar::ConfigurationError, /geo/)
      expect { config.hierarchies = [] }.to raise_error(Gar::ConfigurationError, /хотя бы одна/)
      expect { config.keep_history = [:reestr_objects] }.to raise_error(Gar::ConfigurationError, /reestr_objects/)
      expect { config.param_types = ["индекс"] }.to raise_error(Gar::ConfigurationError, /индекс/)
    end

    it "по умолчанию грузит все субъекты и подрезает иерархии под загруженные объекты" do
      expect(config.region_codes).to eq([])
      expect(config.prune_hierarchy).to be(true)
    end

    it "приводит коды субъектов к именам папок архива и отвергает остальные" do
      config.region_codes = [43, "11", 1, "43"]
      expect(config.region_codes).to eq(["43", "11", "01"])

      ["4", "043", "Киров", 100].each do |code|
        expect { config.region_codes = [code] }.to raise_error(Gar::ConfigurationError, /две цифры.*#{Regexp.escape(code.inspect)}/)
      end
    end
  end

  it "хранит одну резервную схему по умолчанию и принимает только неотрицательное число" do
    expect(config.keep_backups).to eq(1)
    config.keep_backups = "0"
    expect(config.keep_backups).to eq(0)
    [-1, "два", nil].each { |value| expect { config.keep_backups = value }.to raise_error(Gar::ConfigurationError, /keep_backups/) }
  end

  describe "логгер" do
    it "по умолчанию пишет в $stdout, а false отключает логи" do
      expect { config.logger.info("видно") }.to output(/видно/).to_stdout_from_any_process

      config.logger = false
      expect { config.logger.info("не видно") }.not_to output.to_stdout_from_any_process
    end

    it "выбирается при первом обращении: берёт Rails.logger, настроенный после конфигурации" do
      rails_logger = Logger.new(File::NULL)
      stub_const("Rails", Module.new { define_singleton_method(:logger) { rails_logger } })

      expect(config.logger).to be(rails_logger)
    end

    it "принимает свой логгер, nil возвращает выбор по умолчанию" do
      custom = Logger.new(File::NULL)
      config.logger = custom
      expect(config.logger).to be(custom)

      config.logger = nil
      expect(config.logger).not_to be(custom)
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
