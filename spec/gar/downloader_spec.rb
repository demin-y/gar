# frozen_string_literal: true

require "webmock/rspec"
require "fileutils"
require "tmpdir"

RSpec.describe Gar::Downloader do
  let(:downloader) { described_class.new }
  let(:dir)        { Dir.mktmpdir("gar_downloads") }
  let(:api)        { "https://fias.nalog.ru/WebServices/Public" }
  let(:url)        { "https://fias-file.nalog.ru/downloads/2026.01.16/gar_xml.zip" }
  let(:zip)        { File.join(dir, "gar_xml_v20260116.zip") }
  let(:version)    { { "VersionId" => 20_260_116, "GarXMLFullURL" => url, "GarXMLDeltaURL" => url.sub("gar_xml", "gar_delta_xml") } }

  before do
    WebMock.disable_net_connect!
    Gar.configure do |config|
      config.full_base_dir     = dir
      config.delta_dir         = File.join(dir, "delta")
      config.api_retry_timeout = 0
    end
  end

  after do
    WebMock.allow_net_connect!
    FileUtils.rm_rf(dir)
  end

  describe "сведения о версиях" do
    it "возвращает последнюю версию и все версии из API ФНС" do
      stub_request(:get, "#{api}/GetLastDownloadFileInfo").to_return(body: version.to_json)
      stub_request(:get, "#{api}/GetAllDownloadFileInfo").to_return(body: [version, { "VersionId" => 1 }].to_json)

      expect(downloader.latest_version).to eq(version)
      expect(downloader.all_versions.size).to eq(2)
      expect(downloader.version_info(20_260_116)).to eq(version)
    end

    it "сообщает об отсутствующей версии, ошибке API и неверном JSON как DownloadError" do
      stub_request(:get, "#{api}/GetAllDownloadFileInfo").to_return(body: "[]")
      stub_request(:get, "#{api}/GetLastDownloadFileInfo").to_return(status: 500).times(3).then.to_return(body: "<html>")

      expect { downloader.version_info(1) }.to raise_error(Gar::DownloadError, /Версия 1 не найдена/)
      expect { downloader.latest_version }.to raise_error(Gar::DownloadError, /500/)
      expect { downloader.latest_version }.to raise_error(Gar::DownloadError, /JSON/)
    end

    it "проверяет сертификат по config.api_ca_file" do
      stub_request(:get, "#{api}/GetLastDownloadFileInfo").to_return(body: version.to_json)
      allow(Net::HTTP).to receive(:start).and_call_original
      Gar.configuration.api_ca_file = "/etc/ssl/russian_trusted_root_ca.pem"

      downloader.latest_version

      expect(Net::HTTP).to have_received(:start).with("fias.nalog.ru", 443, hash_including(ca_file: "/etc/ssl/russian_trusted_root_ca.pem"))
    end

    it "повторяет запрос при сетевой ошибке и ответах 5xx и 429" do
      stub_request(:get, "#{api}/GetLastDownloadFileInfo").to_raise(Errno::ECONNRESET).then.to_return(status: 503).then
                                                          .to_return(status: 429).then.to_return(body: version.to_json)
      Gar.configuration.api_retry_attempts = 4

      expect(downloader.latest_version).to eq(version)
    end
  end

  describe "загрузка архива" do
    it "скачивает полную выгрузку под именем с версией и сообщает прогресс" do
      stub_request(:get, url).to_return(body: "0123456789", headers: { "Content-Length" => "10" })
      progress = []

      expect(downloader.download_full_base(version, on_progress: ->(*args) { progress << args })).to eq(zip)
      expect(File.read(zip)).to eq("0123456789")
      expect(progress.first).to eq([0, 10, :download])
      expect(progress.last).to eq([10, 10, :download])
      expect(Dir.children(dir)).to eq([File.basename(zip)])
    end

    it "Gar.download качает последнюю версию или заданную" do
      stub_request(:get, "#{api}/GetLastDownloadFileInfo").to_return(body: version.to_json)
      stub_request(:get, "#{api}/GetAllDownloadFileInfo").to_return(body: [version].to_json)
      stub_request(:get, url).to_return(body: "0123456789")

      expect(Gar.download).to eq(zip)
      expect(Gar.download(20_260_116)).to eq(zip)
      expect { Gar.download(1) }.to raise_error(Gar::DownloadError, /не найдена/)
    end

    it "второй процесс, пока первый качает архив, получает LockedError" do
      File.open("#{zip}.lock", File::RDWR | File::CREAT) do |lock|
        lock.flock(File::LOCK_EX)

        expect { downloader.download_full_base(version) }.to raise_error(Gar::LockedError, /уже скачивает/)
      end
      expect(File.exist?(zip)).to be(false)
    end

    it "скачивает дельту в delta_dir" do
      stub_request(:get, version["GarXMLDeltaURL"]).to_return(body: "delta")

      path = downloader.download_delta(version)

      expect(path).to eq(File.join(dir, "delta", "gar_delta_xml_v20260116.zip"))
      expect(File.read(path)).to eq("delta")
    end

    it "продолжает недокачанный .part запросом Range" do
      File.write("#{zip}.part", "01234")
      stub_request(:get, url).with(headers: { "Range" => "bytes=5-" })
                             .to_return(status: 206, body: "56789", headers: { "Content-Range" => "bytes 5-9/10" })

      downloader.download_full_base(version)

      expect(File.read(zip)).to eq("0123456789")
      expect(File.exist?("#{zip}.part")).to be(false)
    end

    it "начинает заново, если сервер не поддерживает Range" do
      File.write("#{zip}.part", "xxxxx")
      stub_request(:get, url).to_return(status: 200, body: "0123456789")

      downloader.download_full_base(version)

      expect(File.read(zip)).to eq("0123456789")
    end

    it "качает заново, если .part не совпадает с файлом на сервере" do
      File.write("#{zip}.part", "лишние байты")
      stub_request(:get, url).to_return(body: "0123456789")
      stub_request(:get, url).with(headers: { "Range" => /bytes=/ }).to_return(status: 416, headers: { "Content-Range" => "bytes */10" })

      downloader.download_full_base(version)

      expect(File.read(zip)).to eq("0123456789")
    end

    it "переименовывает .part, если он уже содержит весь файл" do
      File.write("#{zip}.part", "0123456789")
      stub_request(:get, url).to_return(status: 416, headers: { "Content-Range" => "bytes */10" })

      downloader.download_full_base(version)

      expect(File.read(zip)).to eq("0123456789")
    end

    it "не скачивает архив повторно" do
      File.write(zip, "готово")

      expect(downloader.download_full_base(version)).to eq(zip)
      expect(WebMock).not_to have_requested(:get, url)
    end

    it "повторяет загрузку при сетевых ошибках" do
      stub_request(:get, url).to_raise(Net::ReadTimeout).then.to_timeout.then.to_return(body: "0123456789")

      downloader.download_full_base(version)

      expect(File.read(zip)).to eq("0123456789")
    end

    it "после api_retry_attempts неудачных попыток подряд — DownloadError, без готового zip" do
      stub_request(:get, url).to_raise(Errno::ECONNRESET)

      expect { downloader.download_full_base(version) }.to raise_error(Gar::DownloadError, /3 попыток/)
      expect(WebMock).to have_requested(:get, url).times(3)
      expect(File.exist?(zip)).to be(false)
    end

    it "не принимает файл, размер которого не совпал с заявленным" do
      stub_request(:get, url).to_return(body: "01234", headers: { "Content-Length" => "10" })

      expect { downloader.download_full_base(version) }.to raise_error(Gar::DownloadError, /Размер файла/)
      expect(File.exist?(zip)).to be(false)
    end

    it "сообщает об ошибке сервера как DownloadError" do
      stub_request(:get, url).to_return(status: 404)

      expect { downloader.download_full_base(version) }.to raise_error(Gar::DownloadError, /404/)
    end
  end

  describe "#remove_outdated" do
    it "удаляет дельты не новее версии и полные архивы старее неё, в том числе в общем каталоге" do
      Gar.configuration.delta_dir = dir
      names = ["gar_delta_xml_v20260120.zip", "gar_delta_xml_v20260123.zip", "gar_delta_xml_v20260127.zip",
               "gar_xml_v20260116.zip", "gar_xml_v20260116_r43_11.zip", "gar_xml_v20260123_r43_11.zip"]
      names.each { FileUtils.touch(File.join(dir, _1)) }

      removed = downloader.remove_outdated(20_260_123)

      expect(removed.map { File.basename(_1) }).to match_array(names.first(2) + names[3, 2])
      expect(Dir.children(dir)).to contain_exactly("gar_delta_xml_v20260127.zip", "gar_xml_v20260123_r43_11.zip")
    end
  end

  describe "#cleanup_old_files" do
    let(:temp_dir) { File.join(dir, "cleanup") }

    let(:keep_versions) { 2 }
    let(:keep_days) { 30 }

    before { FileUtils.mkdir_p(temp_dir) }

    it "не считает дублями полный и частичные архивы одной версии" do
      names = ["gar_xml_v20261002.zip", "gar_xml_v20261002_r11_43.zip", "gar_xml_v20261002_r77.zip"]
      names.each_with_index { |name, index| FileUtils.touch(File.join(temp_dir, name), mtime: Time.now - index) }

      expect(downloader.cleanup_old_files(directory: temp_dir, keep_versions: 1)).to eq([])
      expect(Dir.children(temp_dir)).to match_array(names)
    end

    context "when directory does not exist" do
      it "возвращает пустой массив" do
        FileUtils.rm_rf(temp_dir)
        result = downloader.cleanup_old_files(directory: temp_dir)
        expect(result).to eq([])
      end
    end

    context "when directory is empty" do
      it "возвращает пустой массив" do
        result = downloader.cleanup_old_files(directory: temp_dir, keep_days: keep_days, keep_versions: keep_versions)
        expect(result).to eq([])
      end
    end

    context "with files to cleanup" do
      let(:old_file) { File.join(temp_dir, "file_v100.zip") }
      let(:recent_file) { File.join(temp_dir, "file_v123.zip") }
      let(:newest_file) { File.join(temp_dir, "file_v124.zip") }
      let(:very_old_file) { File.join(temp_dir, "file_v99.zip") }

      before do
        FileUtils.touch(old_file, mtime: Time.now - ((keep_days + 10) * 24 * 60 * 60))
        FileUtils.touch(recent_file, mtime: Time.now - (5 * 24 * 60 * 60))
        FileUtils.touch(newest_file, mtime: Time.now - (1 * 24 * 60 * 60))
        FileUtils.touch(very_old_file, mtime: Time.now - ((keep_days + 50) * 24 * 60 * 60))

        File.write(old_file, "content")
        File.write(recent_file, "content")
        File.write(newest_file, "content")
        File.write(very_old_file, "content")
      end

      it "не удаляет файлы в режиме dry_run" do
        result = downloader.cleanup_old_files(
          directory:     temp_dir,
          keep_days:     keep_days,
          keep_versions: keep_versions,
          dry_run:       true
        )

        expect(File.exist?(old_file)).to be true
        expect(File.exist?(very_old_file)).to be true
        expect(result).to be_an(Array)
      end

      it "выводит сообщение о dry run" do
        allow(Gar.logger).to receive(:info)
        downloader.cleanup_old_files(
          directory: temp_dir, keep_days: keep_days, keep_versions: keep_versions, dry_run: true
        )
        expect(Gar.logger).to have_received(:info).with(/Dry run завершен/)
      end

      it "удаляет файлы старше keep_days" do
        result = downloader.cleanup_old_files(
          directory:     temp_dir,
          keep_days:     keep_days,
          keep_versions: keep_versions,
          dry_run:       false
        )

        expect(File.exist?(old_file)).to be false
        expect(File.exist?(very_old_file)).to be false
        expect(File.exist?(recent_file)).to be true
        expect(result).to include(old_file, very_old_file)
      end

      it "оставляет только последние keep_versions версий" do
        file_v121 = File.join(temp_dir, "file_v121.zip")
        file_v122 = File.join(temp_dir, "file_v122.zip")
        FileUtils.touch(file_v121, mtime: Time.now - (10 * 24 * 60 * 60))
        FileUtils.touch(file_v122, mtime: Time.now - (8 * 24 * 60 * 60))
        File.write(file_v121, "content")
        File.write(file_v122, "content")

        downloader.cleanup_old_files(
          directory:     temp_dir,
          keep_days:     100,
          keep_versions: keep_versions,
          dry_run:       false
        )

        expect(File.exist?(file_v121)).to be false
        expect(File.exist?(file_v122)).to be false
        expect(File.exist?(recent_file)).to be true
        expect(File.exist?(newest_file)).to be true
      end

      it "возвращает пустой массив когда нет файлов для удаления" do
        FileUtils.rm_rf(temp_dir)
        FileUtils.mkdir_p(temp_dir)
        FileUtils.touch(recent_file, mtime: Time.now - (5 * 24 * 60 * 60))
        File.write(recent_file, "content")

        result = downloader.cleanup_old_files(
          directory:     temp_dir,
          keep_days:     100,
          keep_versions: 10,
          dry_run:       false
        )

        expect(result).to eq([])
      end

      it "обрабатывает ошибку удаления и продолжает работу" do
        allow(File).to receive(:delete).with(old_file).and_raise(Errno::EACCES, "Permission denied")
        allow(File).to receive(:delete).with(very_old_file).and_call_original
        allow(Gar.logger).to receive(:info)
        allow(Gar.logger).to receive(:debug)
        allow(Gar.logger).to receive(:error)

        downloader.cleanup_old_files(
          directory:     temp_dir,
          keep_days:     keep_days,
          keep_versions: keep_versions,
          dry_run:       false
        )

        expect(Gar.logger).to have_received(:error).with(/Ошибка удаления/)
        expect(File.exist?(old_file)).to be true
        expect(File.exist?(very_old_file)).to be false
      end
    end
  end
end
