# frozen_string_literal: true

require "webmock/rspec"

# Частичная загрузка полной выгрузки (Gar::Downloader::Partial): сервер с HTTP Range отдаёт
# синтетический архив, из него собирается zip только нужных субъектов и таблиц
RSpec.describe Gar::Downloader::Partial do
  include_context "с синтетическим архивом"

  let(:downloads) { File.join(archive_dir, "downloads") }
  let(:url)       { "https://fias-file.nalog.ru/downloads/2026.01.16/gar_xml.zip" }
  let(:version)   { { "VersionId" => 20_260_116, "GarXMLFullURL" => url } }
  let(:tables)    { Gar.configuration.import_tables }
  let(:requests)  { [] }
  # Байт, запросы с которого получают 503 (сервер «лежит» на этом файле), пока он задан
  let(:outage)    { {} }

  before do
    WebMock.disable_net_connect!
    Gar.configure do |config|
      config.full_base_dir     = downloads
      config.api_retry_timeout = 0
    end
  end

  after { WebMock.allow_net_connect! }

  # Сервер архива file: HEAD с размером, GET — целиком или часть по Range; truncate — первый
  # ответ на запрос части, начинающейся с этого байта, обрывается на половине
  def serve(file, ranges: true, truncate: nil)
    data = File.binread(file)
    stub_request(:head, url).to_return(headers: { "Content-Length" => data.bytesize.to_s, **(ranges ? { "Accept-Ranges" => "bytes" } : {}) })
    stub_request(:get, url).to_return do |request|
      range = request.headers["Range"]
      requests << range
      ranges && range ? part(data, range, truncate:) : { body: data }
    end
  end

  def part(data, range, truncate:)
    from, to = range.match(/bytes=(\d+)-(\d+)/).captures.map(&:to_i)
    return { status: 503 } if from == outage[:from]

    to = from + ((to - from) / 2) if from == truncate && requests.count(range) == 1
    { status: 206, body: data.byteslice(from..to), headers: { "Content-Range" => "bytes #{from}-#{to}/#{data.bytesize}" } }
  end

  def download(codes, **) = Gar::Downloader.new.download_full_base(version, region_codes: codes, **)

  # Содержимое файлов таблиц субъектов codes: имя → распакованные данные (с проверкой CRC32)
  def contents(zip, codes) = Gar::Archive.new(zip).jobs(tables, region_codes: codes).to_h { [_1.to_s, Gar::Archive.new(zip).stream(_1, &:read)] }

  it "качает только справочники и файлы загружаемых таблиц нужных субъектов, с прогрессом" do
    serve(zip_path)
    progress = []

    path = download(["43", "11"], on_progress: ->(*args) { progress << args })

    expect(File.basename(path)).to eq("gar_xml_v20260116_r11_43.zip")
    names = Zip::File.open(path) { |zip| zip.entries.map(&:name) }
    expect(names).to include("version.txt").and(include(match(%r{\A43/AS_HOUSES_\d})))
    expect(names.grep(%r{\A(77|50|80)/})).to be_empty
    expect(names.grep(/AS_STEADS/)).to be_empty # участков нет в наборе :minimal
    expect(contents(path, ["43", "11"])).to eq(contents(zip_path, ["43", "11"]))
    expect(Gar::Archive.new(path)).to have_attributes(version_id: 20_260_116, partial: { regions: ["11", "43"], tables: tables.select(&:regional).map(&:name) })
    expect(progress.first).to eq([0, progress.last[1], :download])
    expect(progress.last[0]).to eq(progress.last[1])
  end

  it "Gar.download берёт субъекты из config.region_codes, импорт выбирает архив с ними" do
    stub_request(:get, "https://fias.nalog.ru/WebServices/Public/GetLastDownloadFileInfo").to_return(body: version.to_json)
    serve(zip_path)
    Gar.configuration.region_codes = ["43"]

    path = Gar.download

    expect(File.basename(path)).to eq("gar_xml_v20260116_r43.zip")
    expect(Gar::Importer.find_latest_full_base_zip(region_codes: ["43"])).to eq(path)
    expect(Gar::Importer.find_latest_full_base_zip(region_codes: ["43", "11"])).to be_nil
    expect(Gar::Importer.find_latest_full_base_zip(region_codes: [])).to be_nil
  end

  it "импорт частичного архива без нужного субъекта или таблицы — ImportError" do
    serve(zip_path)
    archive = Gar::Archive.new(download(["43"]))

    expect { archive.jobs(tables, region_codes: ["11"]) }.to raise_error(Gar::ImportError, /частичный \(субъекты 43/)
    expect { archive.jobs(tables, region_codes: []) }.to raise_error(Gar::ImportError, /частичный/)
    expect { archive.jobs(tables + [Gar::Schema.fetch(:steads)], region_codes: ["43"]) }.to raise_error(Gar::ImportError)
    expect(archive.jobs(tables, region_codes: ["43"])).not_to be_empty
  end

  it "продолжает файл с места обрыва" do
    data   = Zip::File.open(zip_path) { |zip| zip.find_entry(zip.entries.map(&:name).grep(%r{\A43/AS_HOUSES_\d}).first) }
    header = File.binread(zip_path, 30, data.local_header_offset).unpack("@26vv").sum + 30
    serve(zip_path, truncate: data.local_header_offset + header)

    path = download(["43"])

    expect(requests.count { _1.start_with?("bytes=#{data.local_header_offset + header}-") }).to eq(1)
    expect(contents(path, ["43"])).to eq(contents(zip_path, ["43"]))
  end

  it "после перезапуска докачивает частичный архив, не запрашивая скачанные файлы заново" do
    zip    = Zip::File.open(zip_path) { |file| file.entries.sort_by(&:local_header_offset) }
    houses = zip.find { _1.name.match?(%r{\A43/AS_HOUSES_\d}) }
    data   = ->(entry) { entry.local_header_offset + 30 + File.binread(zip_path, 4, entry.local_header_offset + 26).unpack("vv").sum }
    serve(zip_path)
    outage[:from] = data.call(houses)

    expect { download(["43"]) }.to raise_error(Gar::DownloadError, /503/)
    expect(Dir.children(downloads)).to include("gar_xml_v20260116_r43.zip.part", "gar_xml_v20260116_r43.zip.part.json")

    outage.clear
    requests.clear
    path = download(["43"])

    done = zip.select { _1.local_header_offset < houses.local_header_offset && !_1.name.match?(%r{\A(11|50|77|80)/}) }
    expect(done.map { "bytes=#{data.call(_1)}-" }).to all(satisfy { |range| requests.none? { _1&.start_with?(range) } })
    expect(contents(path, ["43"])).to eq(contents(zip_path, ["43"]))
    expect(Dir.children(downloads)).to eq(["gar_xml_v20260116_r43.zip"])
  end

  it "сервер без Range: download_mode :partial — ошибка с причиной, :auto — полный архив; затем он же для любых субъектов" do
    serve(zip_path, ranges: false)
    Gar.configuration.download_mode = :partial
    expect { download(["43"]) }.to raise_error(Gar::DownloadError, /не отдаёт части файла.*download_mode = :auto или :full/)

    Gar.configuration.download_mode = :auto
    path = download(["43"])

    expect(File.basename(path)).to eq("gar_xml_v20260116.zip")
    expect(File.binread(path)).to eq(File.binread(zip_path))
    expect(download(["11"])).to eq(path)
  end

  it "архив с теми же субъектами в другом порядке не качает заново" do
    serve(zip_path)
    path = download(["43", "11"])
    requests.clear

    expect(download(["11", "43"])).to eq(path)
    expect(File.basename(path)).to eq("gar_xml_v20260116_r11_43.zip")
    expect(requests).to be_empty
  end

  it "сервер без размера в ответе на HEAD — как без Range: полный архив" do
    serve(zip_path)
    stub_request(:head, url).to_return(headers: { "Accept-Ranges" => "bytes" })

    expect(File.basename(download(["43"]))).to eq("gar_xml_v20260116.zip")
  end

  it "download_mode :full качает весь архив и с субъектами" do
    serve(zip_path)
    Gar.configuration.download_mode = :full

    expect(File.basename(download(["43"]))).to eq("gar_xml_v20260116.zip")
    expect { Gar.configuration.download_mode = :fast }.to raise_error(Gar::ConfigurationError, /download_mode/)
  end

  it "пишет и читает Zip64: большие размеры и смещения — в дополнительном поле" do
    serve(zip_path)
    stub_const("Gar::Downloader::Partial::ZIP64_LIMIT", 1)
    zip64 = download(["43", "11"])
    expect(contents(zip64, ["43", "11"])).to eq(contents(zip_path, ["43", "11"]))

    FileUtils.mv(zip64, File.join(archive_dir, "zip64.zip"))
    WebMock.reset!
    serve(File.join(archive_dir, "zip64.zip"))
    expect(contents(download(["43"]), ["43"])).to eq(contents(zip_path, ["43"]))
  end
end
