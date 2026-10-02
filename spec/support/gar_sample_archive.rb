# frozen_string_literal: true

# Синтетический zip из связного набора Gar::TestSupport::Sample (описание набора — там)
# плюс пустой субъект 80: все 18 файлов без записей. version — другая дата выгрузки для того же
# набора (обновление полным импортом).
module GarSampleArchive
  module_function

  def build(version: Gar::TestSupport::Sample::VERSION)
    sample  = Gar::TestSupport::Sample
    builder = GarArchiveBuilder.new(version:)
    sample.root.each { |name, records| builder.root(file_key(name), *records) }
    sample.regions.each { |code, tables| tables.each { |name, records| builder.region(code, file_key(name), *records) } }
    builder.region("80")
  end

  # Ключ файла в GarArchiveBuilder: таблица houses → файл AS_HOUSES → :houses
  def file_key(name) = Gar::Schema.fetch(name).file.downcase.to_sym
end
