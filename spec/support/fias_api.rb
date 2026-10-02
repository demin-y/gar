# frozen_string_literal: true

require "json"

# Заглушки API ФНС (WebMock) для спек обновления: список выгрузок и архивы
module FiasApi
  API       = "https://fias.nalog.ru/WebServices/Public"
  DOWNLOADS = "https://fias-file.nalog.ru/downloads"

  # Выгрузки в API ФНС: VersionId → { delta:, full: } — архивы, которые отдаёт сервер
  def stub_fias_versions(list)
    infos =
      list.map do |id, files|
        { "VersionId" => id, "GarXMLDeltaURL" => stub_archive(id, :delta, files), "GarXMLFullURL" => stub_archive(id, :full, files) }
      end
    stub_request(:get, "#{API}/GetAllDownloadFileInfo").to_return(body: infos.to_json)
    stub_request(:get, "#{API}/GetLastDownloadFileInfo").to_return(body: infos.max_by { _1["VersionId"] }.to_json)
  end

  # Ссылка на архив kind выгрузки id ("" — архива нет); сервер отдаёт files[kind]
  def stub_archive(id, kind, files)
    return "" unless files[kind]

    "#{DOWNLOADS}/#{id}/gar_#{kind}_xml.zip".tap { stub_request(:get, _1).to_return(body: File.binread(files[kind])) }
  end
end
