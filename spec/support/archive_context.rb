# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Синтетический архив во временном каталоге; каталог удаляется после примера
RSpec.shared_context "с синтетическим архивом" do
  let(:archive_dir)     { Dir.mktmpdir("gar_archive") }
  let(:archive_builder) { GarSampleArchive.build }
  let(:zip_path)        { archive_builder.write(archive_dir) }

  after { FileUtils.rm_rf(archive_dir) }
end
