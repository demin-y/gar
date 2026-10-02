# frozen_string_literal: true

RSpec.describe Gar::Schema do
  it "описывает все таблицы реального архива: 10 справочников корня и 18 таблиц субъекта" do
    file_key = ->(key) { key.to_s.upcase }

    expect(described_class::DICTIONARIES.map(&:file)).to match_array(GarArchiveBuilder::ROOT_FILES.keys.map(&file_key))
    expect(described_class::REGIONAL.map(&:file)).to match_array(GarArchiveBuilder::REGION_FILES.keys.map(&file_key))
  end

  described_class::TABLES.each_value do |table|
    describe "таблица #{table.name}" do
      let(:xsd) { XsdRecord.read(table) }

      it "разбирает элемент записи из XSD" do
        expect(table.element).to eq(xsd.first)
      end

      it "хранит все атрибуты XSD, кроме явно пропущенных, и только их" do
        expect(table.columns.map(&:attribute) + table.ignored).to match_array(xsd.last.keys)
      end

      it "задаёт колонкам типы, совместимые с XSD" do
        mismatched = table.columns.reject { XsdRecord.compatible?(_1.type, **xsd.last.fetch(_1.attribute)) }

        expect(mismatched.map { "#{_1.name}: #{_1.type} ≠ #{xsd.last[_1.attribute]}" }).to be_empty
      end
    end
  end

  describe "SQL" do
    let(:houses) { described_class.fetch(:houses) }

    it "создаёт таблицу с колонками XML, кодом субъекта, производными колонками путей и вычисляемым номером" do
      expect(houses.create_sql("gar_v1")).to start_with('CREATE TABLE "gar_v1"."houses" ("id" bigint, ')
        .and include('"object_guid" uuid', '"add_num1" text', '"is_active" boolean, "region_code" text, "full_adm_path" text')
        .and include('"full_mun_path_tsv" tsvector, "adm_path_ids" bigint[], "mun_path_ids" bigint[]')
        .and end_with('"house_num_norm" text GENERATED ALWAYS AS (translate(lower(regexp_replace(house_num, \'\\s+\', \'\', \'g\')), \'ё\', \'е\')) STORED)')
    end

    it "загружает COPY колонки XML и код субъекта, но не производные" do
      expect(houses.copy_sql("s")).to start_with('COPY "s"."houses" ("id", "object_id", "object_guid", ')
        .and end_with('"is_active", "region_code") FROM STDIN')
    end

    it "строит первичный ключ и индексы по описанию" do
      expect(houses.index_sqls("s")).to eq([
                                             'ALTER TABLE "s"."houses" ADD PRIMARY KEY ("id")',
                                             'CREATE INDEX "idx_houses_object_id" ON "s"."houses" ("object_id")',
                                             'CREATE INDEX "idx_houses_object_guid" ON "s"."houses" ("object_guid")'
                                           ])
      expect(described_class.fetch(:change_history).index_sqls("s"))
        .to eq(['CREATE INDEX "idx_change_history_object_id" ON "s"."change_history" ("object_id")'])
    end

    it "выполняет DDL всех таблиц в PostgreSQL", :db do
      schema = isolated_schema("gar_schema")
      db_connection.exec("CREATE SCHEMA #{schema}")

      described_class::TABLES.each_value do |table|
        db_connection.exec(table.create_sql(schema))
        table.index_sqls(schema).each { db_connection.exec(_1) }
      end

      expect(tables_in(schema)).to match_array(described_class::TABLES.keys)
    end
  end

  it "сообщает о неизвестной таблице ошибкой конфигурации" do
    expect { described_class.fetch(:params) }.to raise_error(Gar::ConfigurationError, /params/)
  end
end
