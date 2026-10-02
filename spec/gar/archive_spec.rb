# frozen_string_literal: true

require "zip"

RSpec.describe Gar::Archive do
  include_context "с синтетическим архивом"

  let(:archive) { described_class.new(zip_path) }

  def build_archive(builder = archive_builder, **)
    described_class.new(builder.write(archive_dir, **))
  end

  def tables(*names) = names.map { Gar::Schema.fetch(_1) }

  def table_and_region(jobs) = jobs.map { [_1.table.name, _1.region_code] }

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
      broken = File.join(archive_dir, "broken.zip").tap { File.write(_1, "не zip") }

      expect { described_class.new(broken).version_id }.to raise_error(Gar::ImportError, /Не удалось прочитать архив broken.zip/)
      expect { described_class.new(File.join(archive_dir, "missing.zip")) }.to raise_error(Gar::ImportError, /не найден/)
    end
  end

  describe "#jobs" do
    it "выбирает файл таблицы по точному имени: AS_ADDR_OBJ не захватывает _PARAMS, _DIVISION и _TYPES" do
      jobs = archive.jobs(tables(:address_objects))

      expect(jobs.map(&:to_s)).to all(match(%r{\A\d{2}/AS_ADDR_OBJ_\d{8}_[-0-9a-f]+\.XML\z}))
      expect(jobs.map(&:region_code)).to contain_exactly("43", "11", "77", "80")
    end

    it "берёт справочники из корня, а таблицы субъектов — из папок, включая пустые" do
      jobs = archive.jobs(tables(:house_types, :houses))

      expect(table_and_region(jobs))
        .to contain_exactly([:house_types, nil], [:houses, "43"], [:houses, "11"], [:houses, "77"], [:houses, "80"])
    end

    it "с region_codes читает только папки этих субъектов и корень" do
      jobs = archive.jobs(tables(:house_types, :houses), region_codes: ["43", "11"])

      expect(table_and_region(jobs)).to contain_exactly([:house_types, nil], [:houses, "43"], [:houses, "11"])
    end

    it "с пустым списком субъектов читает все папки" do
      expect(archive.jobs(tables(:houses), region_codes: []).size).to eq(4)
    end

    it "ставит крупные файлы первыми и знает их несжатый размер" do
      jobs = archive.jobs(Gar::Schema::TABLES.values)

      expect(jobs.size).to eq(10 + (18 * 4))
      expect(jobs.map(&:size)).to eq(jobs.map(&:size).sort.reverse)
      expect(jobs.first.size).to eq(archive.stream(jobs.first) { _1.read.bytesize })
    end

    it "пропускает посторонние файлы и таблицы не на своём месте" do
      archive_builder.file("readme.txt", "не XML")
                     .file("43/AS_HOUSE_TYPES_20260115_x.XML", "<HOUSETYPES />")
                     .file("AS_HOUSES_20260115_y.XML", "<HOUSES />")
                     .file("43/AS_UNKNOWN_20260115_z.XML", "<ITEMS />")

      jobs = archive.jobs(tables(:house_types, :houses))

      expect(table_and_region(jobs))
        .to contain_exactly([:house_types, nil], [:houses, "43"], [:houses, "11"], [:houses, "77"], [:houses, "80"])
    end
  end

  describe "#stream" do
    def job_for(entry_prefix)
      archive.jobs(Gar::Schema::TABLES.values).find { _1.to_s.start_with?(entry_prefix) }
    end

    it "читает XML файла потоком из zip, ничего не распаковывая на диск" do
      expect(archive.stream(job_for("77/AS_HOUSES_2"), &:read)).to include('HOUSENUM="1"')
      expect(Dir.children(archive_dir)).to eq([File.basename(zip_path)])
    end

    it "читает и файлы без сжатия" do
      path = File.join(archive_dir, "stored.zip")
      Zip::OutputStream.open(path) do |zip|
        zip.put_next_entry("version.txt", "", Zip::ExtraField.new, Zip::Entry::STORED)
        zip.write("2026.02.01\nv.224")
      end

      expect(described_class.new(path).version_id).to eq(20_260_201)
    end

    it "замечает повреждённые данные по CRC32" do
      job = job_for("43/AS_HOUSES_2")
      corrupt_data_byte(job)

      expect { described_class.new(zip_path).stream(job, &:read) }.to raise_error(Gar::ImportError, %r{43/AS_HOUSES_.*повреждён})
    end

    it "замечает обрезанный архив" do
      job = job_for("43/AS_HOUSES_2")
      File.truncate(zip_path, job.entry.offset + 100)

      expect { archive.stream(job, &:read) }.to raise_error(Gar::ImportError, /архив обрезан|повреждён/)
    end

    # Портит последний байт сжатых данных файла
    def corrupt_data_byte(job)
      File.open(zip_path, "r+b") do |file|
        file.seek(job.entry.offset + 26)
        name_length, extra_length = file.read(4).unpack("vv")
        position = job.entry.offset + 30 + name_length + extra_length + job.entry.compressed_size - 1
        file.seek(position)
        byte = file.read(1).ord
        file.seek(position)
        file.write((byte ^ 0xFF).chr)
      end
    end
  end
end
