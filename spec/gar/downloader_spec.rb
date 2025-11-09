# frozen_string_literal: true

require "webmock/rspec"
require "fileutils"
require "tempfile"

RSpec.describe Gar::Downloader do
  let(:downloader) { described_class.new }

  before do
    WebMock.disable_net_connect!
  end

  after do
    WebMock.allow_net_connect!
  end

  # ============================================================================
  # API методы — получение информации о версиях
  # ============================================================================

  describe "#all_versions" do
    let(:mock_versions) { [{ "VersionId" => 1, "Date" => "2023-01-01" }] }
    let(:base_url) { "https://example.com" }

    context "when SSL verification is enabled" do
      before do
        allow(Gar.configuration).to receive_messages(
          api_ssl_verify:       true,
          api_all_versions_url: "#{base_url}/GetAllDownloadFileInfo"
        )
        stub_request(:get, "#{base_url}/GetAllDownloadFileInfo")
          .to_return(body: mock_versions.to_json)
      end

      it "получает все версии из FIAS API" do
        versions = downloader.all_versions
        expect(versions).to eq(mock_versions)
      end

      it "выполняет корректный HTTP запрос" do
        downloader.all_versions
        expect(WebMock).to have_requested(:get, "#{base_url}/GetAllDownloadFileInfo")
      end
    end

    context "when SSL verification is disabled" do
      before do
        allow(Gar.configuration).to receive_messages(
          api_ssl_verify:       false,
          api_all_versions_url: "#{base_url}/GetAllDownloadFileInfo"
        )
        stub_request(:get, "#{base_url}/GetAllDownloadFileInfo")
          .to_return(body: mock_versions.to_json)
      end

      it "отключает SSL верификацию" do
        allow(Gar.logger).to receive(:warn)
        downloader.all_versions
        expect(Gar.logger).to have_received(:warn).with(/SSL верификация отключена/)
        expect(WebMock).to have_requested(:get, "#{base_url}/GetAllDownloadFileInfo")
      end
    end
  end

  describe "#latest_version" do
    let(:mock_version) { { "VersionId" => 123, "Date" => "2023-12-01" } }
    let(:base_url) { "https://example.com" }

    context "when SSL verification is enabled" do
      before do
        allow(Gar.configuration).to receive_messages(
          api_ssl_verify:         true,
          api_latest_version_url: "#{base_url}/GetLastDownloadFileInfo"
        )
        stub_request(:get, "#{base_url}/GetLastDownloadFileInfo")
          .to_return(body: mock_version.to_json)
      end

      it "получает последнюю версию из FIAS API" do
        version = downloader.latest_version
        expect(version).to eq(mock_version)
      end
    end

    context "when SSL verification is disabled" do
      before do
        allow(Gar.configuration).to receive_messages(
          api_ssl_verify:         false,
          api_latest_version_url: "#{base_url}/GetLastDownloadFileInfo"
        )
        stub_request(:get, "#{base_url}/GetLastDownloadFileInfo")
          .to_return(body: mock_version.to_json)
      end

      it "отключает SSL верификацию" do
        allow(Gar.logger).to receive(:warn)
        downloader.latest_version
        expect(Gar.logger).to have_received(:warn).with(/SSL верификация отключена/)
      end
    end
  end

  describe "#version_info" do
    let(:version_id) { 123 }
    let(:mock_versions) do
      [
        { "VersionId" => 121, "Date" => "2023-01-01" },
        { "VersionId" => version_id, "Date" => "2023-12-01" },
        { "VersionId" => 125, "Date" => "2024-01-01" }
      ]
    end

    before do
      allow(downloader).to receive(:all_versions).and_return(mock_versions)
    end

    it "возвращает информацию о версии по version_id" do
      version = downloader.version_info(version_id)
      expect(version["VersionId"]).to eq(version_id)
    end

    it "выбрасывает ошибку для несуществующей версии" do
      expect { downloader.version_info(999) }.to raise_error(Gar::Error, "Версия 999 не найдена")
    end
  end

  # ============================================================================
  # Методы загрузки — высокоуровневые операции
  # ============================================================================

  describe "#download_full_base" do
    let(:version_info) { { "GarXMLFullURL" => "http://example.com/full.zip", "VersionId" => 123 } }

    before do
      allow(downloader).to receive(:download).and_return("/path/to/file.zip")
    end

    it "вызывает download с корректными параметрами" do
      zip_path = downloader.download_full_base(version_info)
      expect(downloader).to have_received(:download).with(
        "http://example.com/full.zip",
        anything,
        hash_including(version_id: 123, show_progress: false)
      )
      expect(zip_path).to eq("/path/to/file.zip")
    end

    context "with show_progress enabled" do
      it "передаёт show_progress в download" do
        downloader.download_full_base(version_info, show_progress: true)
        expect(downloader).to have_received(:download).with(
          anything,
          anything,
          hash_including(show_progress: true)
        )
      end
    end
  end

  describe "#download_delta" do
    let(:version_info) { { "GarXMLDeltaURL" => "http://example.com/delta.zip", "VersionId" => 123 } }

    before do
      allow(downloader).to receive(:download).and_return("/path/to/file.zip")
    end

    it "вызывает download с корректными параметрами" do
      zip_path = downloader.download_delta(version_info)
      expect(downloader).to have_received(:download).with(
        "http://example.com/delta.zip",
        anything,
        hash_including(version_id: 123, show_progress: false)
      )
      expect(zip_path).to eq("/path/to/file.zip")
    end

    context "with show_progress enabled" do
      it "передаёт show_progress в download" do
        downloader.download_delta(version_info, show_progress: true)
        expect(downloader).to have_received(:download).with(
          anything,
          anything,
          hash_including(show_progress: true)
        )
      end
    end
  end

  describe "#download (private)" do
    let(:url) { "http://example.com/file.zip" }
    let(:target_dir) { Dir.mktmpdir }
    let(:version_id) { 123 }

    before do
      stub_request(:head, url)
        .to_return(status: 200, headers: { "Content-Length" => "1000" })
      stub_request(:get, url)
        .to_return(status: 200, body: "fake zip content")
      allow(downloader).to receive(:download_file)
      allow(downloader).to receive(:generate_filename).and_return("file_v123.zip")
      allow(File).to receive(:size).and_return(1000)
    end

    after do
      FileUtils.rm_rf(target_dir)
    end

    it "создаёт целевую директорию если она не существует" do
      FileUtils.rm_rf(target_dir)
      downloader.send(:download, url, target_dir, version_id: version_id)
      expect(Dir.exist?(target_dir)).to be true
    end

    it "генерирует имя файла с version_id" do
      downloader.send(:download, url, target_dir, version_id: version_id)
      expect(downloader).to have_received(:generate_filename).with(url, version_id)
    end

    it "вызывает download_file с корректными параметрами" do
      downloader.send(:download, url, target_dir, version_id: version_id, show_progress: false)
      expect(downloader).to have_received(:download_file).with(url, anything, show_progress: false)
    end

    it "возвращает путь к скачанному файлу" do
      zip_path = downloader.send(:download, url, target_dir, version_id: version_id)
      expect(zip_path).to be_a(String)
      expect(zip_path).to include("file_v123.zip")
    end

    context "with show_progress enabled" do
      it "передаёт show_progress в download_file" do
        downloader.send(:download, url, target_dir, version_id: version_id, show_progress: true)
        expect(downloader).to have_received(:download_file).with(anything, anything, show_progress: true)
      end
    end
  end

  describe "#download_file (private)" do
    let(:url) { "http://example.com/file.zip" }
    let(:destination_path) { File.join(Dir.mktmpdir, "file.zip") }
    let(:temp_dir) { File.dirname(destination_path) }

    before do
      allow(Gar.configuration).to receive_messages(api_retry_attempts: 3, api_retry_timeout: 0.01)
      stub_request(:head, url)
        .to_return(status: 200, headers: { "Content-Length" => "1000" })
      FileUtils.mkdir_p(temp_dir)
    end

    after do
      FileUtils.rm_rf(temp_dir)
    end

    context "when download succeeds" do
      before do
        stub_request(:get, url)
          .to_return(status: 200, body: "fake zip content")
        allow(File).to receive(:exist?).with(destination_path).and_return(false)
        allow(File).to receive(:size).with(destination_path).and_return(0, 1000)
        allow(downloader).to receive(:perform_download).and_return(1000)
      end

      it "загружает файл успешно" do
        expect { downloader.send(:download_file, url, destination_path) }.not_to raise_error
      end

      it "вызывает perform_download с корректными параметрами" do
        downloader.send(:download_file, url, destination_path, show_progress: false)
        expect(downloader).to have_received(:perform_download).with(
          url, destination_path, false, 0, false
        )
      end
    end

    context "when resuming download" do
      before do
        allow(File).to receive(:exist?).with(destination_path).and_return(true)
        allow(File).to receive(:size).with(destination_path).and_return(500, 1000)
        stub_request(:get, url)
          .with(headers: { "Range" => "bytes=500-" })
          .to_return(status: 206, body: "remaining content")
        allow(downloader).to receive(:perform_download).and_return(1000)
      end

      it "возобновляет загрузку с существующего файла" do
        downloader.send(:download_file, url, destination_path)
        expect(downloader).to have_received(:perform_download).with(
          url, destination_path, true, 500, false
        )
      end
    end

    context "when network errors occur" do
      before do
        allow(File).to receive(:exist?).with(destination_path).and_return(false)
        allow(File).to receive(:size).with(destination_path).and_return(0)
      end

      it "повторяет попытку при Net::ReadTimeout" do
        call_count = 0
        allow(downloader).to receive(:perform_download) do
          call_count += 1
          raise Net::ReadTimeout if call_count <= 2

          1000
        end
        stub_request(:get, url).to_return(status: 200, body: "content")

        expect { downloader.send(:download_file, url, destination_path) }.not_to raise_error
      end

      it "повторяет попытку при Net::OpenTimeout" do
        call_count = 0
        allow(downloader).to receive(:perform_download) do
          call_count += 1
          raise Net::OpenTimeout if call_count <= 2

          1000
        end

        expect { downloader.send(:download_file, url, destination_path) }.not_to raise_error
      end

      it "повторяет попытку при Errno::ECONNRESET" do
        call_count = 0
        allow(downloader).to receive(:perform_download) do
          call_count += 1
          raise Errno::ECONNRESET if call_count <= 2

          1000
        end

        expect { downloader.send(:download_file, url, destination_path) }.not_to raise_error
      end

      it "повторяет попытку при Errno::ETIMEDOUT" do
        call_count = 0
        allow(downloader).to receive(:perform_download) do
          call_count += 1
          raise Errno::ETIMEDOUT if call_count <= 2

          1000
        end

        expect { downloader.send(:download_file, url, destination_path) }.not_to raise_error
      end

      it "повторяет попытку при SocketError" do
        call_count = 0
        allow(downloader).to receive(:perform_download) do
          call_count += 1
          raise SocketError if call_count <= 2

          1000
        end

        expect { downloader.send(:download_file, url, destination_path) }.not_to raise_error
      end

      it "выбрасывает ошибку после исчерпания попыток" do
        stub_request(:get, url).to_timeout
        allow(downloader).to receive(:perform_download).and_raise(Net::ReadTimeout)

        expect { downloader.send(:download_file, url, destination_path) }.to raise_error(Net::ReadTimeout)
      end

      it "не повторяет попытку при не-сетевых ошибках" do
        allow(downloader).to receive(:perform_download).and_raise(RuntimeError, "Непредвиденная ошибка")

        expect { downloader.send(:download_file, url, destination_path) }.to raise_error(RuntimeError, "Непредвиденная ошибка")
        expect(downloader).to have_received(:perform_download).once
      end
    end
  end

  # ============================================================================
  # Методы очистки
  # ============================================================================

  describe "#cleanup_old_files" do
    let(:temp_dir) { Dir.mktmpdir }
    let(:keep_days) { 30 }
    let(:keep_versions) { 2 }

    before do
      allow(Gar.configuration).to receive(:full_base_dir).and_return(temp_dir)
      FileUtils.mkdir_p(temp_dir)
    end

    after do
      FileUtils.rm_rf(temp_dir)
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

  # ============================================================================
  # Вспомогательные методы (private) — форматирование и генерация имён файлов
  # ============================================================================

  describe "#format_bytes (private)" do
    it "возвращает '0 B' для нуля байт" do
      expect(downloader.send(:format_bytes, 0)).to eq("0 B")
    end

    it "форматирует байты корректно" do
      expect(downloader.send(:format_bytes, 512)).to eq("512.0 B")
    end

    it "форматирует килобайты корректно" do
      expect(downloader.send(:format_bytes, 2048)).to eq("2.0 KB")
    end

    it "форматирует мегабайты корректно" do
      expect(downloader.send(:format_bytes, 2 * 1024 * 1024)).to eq("2.0 MB")
    end

    it "форматирует гигабайты корректно" do
      expect(downloader.send(:format_bytes, 2 * 1024 * 1024 * 1024)).to eq("2.0 GB")
    end

    it "округляет значения корректно" do
      expect(downloader.send(:format_bytes, 1536)).to eq("1.5 KB")
    end
  end

  describe "#generate_filename (private)" do
    it "генерирует имя файла с version_id" do
      url = "http://example.com/file.zip"
      filename = downloader.send(:generate_filename, url, 123)
      expect(filename).to eq("file_v123.zip")
    end

    it "заменяет специальные символы на подчёркивания" do
      url = "http://example.com/file-name@123.zip"
      filename = downloader.send(:generate_filename, url, 123)
      expect(filename).to eq("file-name_123_v123.zip")
    end

    it "не добавляет версию если URL без расширения .zip" do
      url = "http://example.com/file"
      filename = downloader.send(:generate_filename, url, 123)
      expect(filename).to eq("file")
    end
  end

  describe "#extract_version_from_filename (private)" do
    it "извлекает версию из имени файла" do
      expect(downloader.send(:extract_version_from_filename, "file_v123.zip")).to eq(123)
    end

    it "возвращает nil когда паттерн версии не найден" do
      expect(downloader.send(:extract_version_from_filename, "file.zip")).to be_nil
    end

    it "обрабатывает полные пути" do
      expect(downloader.send(:extract_version_from_filename, "/path/to/file_v456.zip")).to eq(456)
    end

    it "обрабатывает имена файлов с несколькими числами" do
      expect(downloader.send(:extract_version_from_filename, "data_2023_v789.zip")).to eq(789)
    end
  end
end
