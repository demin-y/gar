# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Gar::Archive do
  let(:dir)     { Dir.mktmpdir("gar_archive") }
  let(:archive) { build_archive }

  after { FileUtils.rm_rf(dir) }

  def build_archive(builder = GarSampleArchive.build, **)
    described_class.new(builder.write(dir, **))
  end

  def tables(*names) = names.map { Gar::Schema.fetch(_1) }

  describe "#version_id" do
    it "берёт версию из version.txt, а не из имени архива" do
      expect(build_archive(name: "gar_xml.zip").version_id).to eq(20_260_116)
    end

    it "без version.txt сообщает, что это не выгрузка ГАР" do
      expect { build_archive(version_txt: nil).version_id }.to raise_error(Gar::ImportError, /нет version.txt/)
    end

    it "сообщает о нечитаемой версии" do
      expect { build_archive(version_txt: "v.223").version_id }.to raise_error(Gar::ImportError, /версию из version.txt: "v.223"/)
    end

    it "сообщает о повреждённом архиве и об отсутствующем файле" do
      broken = File.join(dir, "broken.zip").tap { File.write(_1, "не zip") }

      expect { described_class.new(broken).version_id }.to raise_error(Gar::ImportError, /Не удалось прочитать архив broken.zip/)
      expect { described_class.new(File.join(dir, "missing.zip")) }.to raise_error(Gar::ImportError, /не найден/)
    end
  end

  describe "#jobs" do
    it "выбирает файл таблицы по точному имени: AS_ADDR_OBJ не захватывает _PARAMS, _DIVISION и _TYPES" do
      jobs = archive.jobs(tables(:address_objects))

      expect(jobs.map(&:entry)).to all(match(%r{\A\d{2}/AS_ADDR_OBJ_\d{8}_[-0-9a-f]+\.XML\z}))
      expect(jobs.map(&:region_code)).to contain_exactly("43", "11", "77", "80")
    end

    it "берёт справочники из корня, а таблицы субъектов — из папок, включая пустые" do
      jobs = archive.jobs(tables(:house_types, :houses))

      expect(jobs.map { [_1.table, _1.region_code] })
        .to contain_exactly([:house_types, nil], [:houses, "43"], [:houses, "11"], [:houses, "77"], [:houses, "80"])
    end

    it "с region_codes читает только папки этих субъектов и корень" do
      jobs = archive.jobs(tables(:house_types, :houses), region_codes: ["43", "11"])

      expect(jobs.map { [_1.table, _1.region_code] }).to contain_exactly([:house_types, nil], [:houses, "43"], [:houses, "11"])
    end

    it "с пустым списком субъектов читает все папки" do
      expect(archive.jobs(tables(:houses), region_codes: []).size).to eq(4)
    end

    it "ставит крупные файлы первыми и знает их несжатый размер" do
      jobs = archive.jobs(Gar::Schema::TABLES.values)

      expect(jobs.size).to eq(10 + (18 * 4))
      expect(jobs.map(&:size)).to eq(jobs.map(&:size).sort.reverse)
      expect(jobs.first.size).to eq(archive.open(jobs.first) { _1.read.bytesize })
    end

    it "пропускает посторонние файлы и таблицы не на своём месте" do
      builder = GarSampleArchive.build
                                .file("readme.txt", "не XML")
                                .file("43/AS_HOUSE_TYPES_20260115_x.XML", "<HOUSETYPES />")
                                .file("AS_HOUSES_20260115_y.XML", "<HOUSES />")
                                .file("43/AS_UNKNOWN_20260115_z.XML", "<ITEMS />")

      jobs = build_archive(builder).jobs(tables(:house_types, :houses))

      expect(jobs.map { [_1.table, _1.region_code] }).to contain_exactly([:house_types, nil], [:houses, "43"], [:houses, "11"],
                                                                         [:houses, "77"], [:houses, "80"])
    end
  end

  describe "#open" do
    it "читает XML файла потоком из zip, ничего не распаковывая" do
      job = archive.jobs(tables(:houses), region_codes: ["77"]).first

      expect(archive.open(job, &:read)).to include('HOUSENUM="1"')
      expect(Dir.children(dir)).to eq([File.basename(archive.path)])
    end
  end
end
