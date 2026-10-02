# frozen_string_literal: true

RSpec.describe Gar::PathBuilder, :db do
  let(:schema)  { isolated_schema("gar_paths") }
  let(:builder) { described_class.new(db_connection, schema:) }

  # Область 1 → город 2 → улица 3 (adm); в муниципальной иерархии город — через округ 4.
  # Дома: 10 на улице, 11 без номера, 12 без строки в иерархии
  def create_tables(*names)
    db_connection.exec("CREATE SCHEMA #{schema}")
    names.each { db_connection.exec(Gar::Schema.fetch(_1).create_sql(schema)) }
  end

  def insert(table, columns, *rows)
    placeholders = columns.each_index.map { "$#{_1 + 1}" }.join(", ")
    rows.each { db_connection.exec_params("INSERT INTO #{schema}.#{table} (#{columns.join(', ')}) VALUES (#{placeholders})", _1) }
  end

  def hierarchy(table, paths)
    insert(table, [:id, :object_id, :path, :is_active], *paths.each_with_index.map { |(object_id, path), id| [id + 1, object_id, path, true] })
  end

  def paths(table, column)
    db_connection.exec("SELECT id, #{column} FROM #{schema}.#{table} ORDER BY id").to_h { [_1["id"].to_i, _1[column]] }
  end

  before do
    create_tables(:address_objects, :houses, :house_types, :adm_hierarchy, :mun_hierarchy)
    columns = [:id, :object_id, :name, :type_name, :is_actual, :is_active]
    insert(:address_objects, columns,
           [1, 1, "Кировская", "обл", true, true], [2, 2, "Киров", "г", true, true], [3, 3, "Ленина", "ул", true, true],
           [4, 4, "город Киров", "г.о.", true, true],
           [5, 3, "Старая", "ул", false, false]) # историческая запись улицы не попадает в пути
    insert(:house_types, [:id, :short_name], [2, "д."])
    insert(:houses, [:id, :object_id, :house_num, :house_type, :is_actual, :is_active],
           [10, 10, "10", 2, true, true], [11, 11, nil, 2, true, true], [12, 12, "12", 2, true, true])
    hierarchy(:adm_hierarchy, 1 => "1", 2 => "1.2", 3 => "1.2.3", 10 => "1.2.3.10", 11 => "1.2.3.11")
    hierarchy(:mun_hierarchy, 1 => "1", 4 => "1.4", 2 => "1.4.2", 3 => "1.4.2.3", 10 => "1.4.2.3.10")
  end

  it "строит административные и муниципальные пути по актуальным записям" do
    builder.build

    expect(paths(:address_objects, "full_adm_path")).to include(3 => "Кировская обл, Киров г, Ленина ул", 4 => nil)
    expect(paths(:address_objects, "full_mun_path")).to include(3 => "Кировская обл, город Киров г.о., Киров г, Ленина ул")
    expect(paths(:houses, "full_adm_path")).to eq(10 => "Кировская обл, Киров г, Ленина ул, д. 10",
                                                  11 => "Кировская обл, Киров г, Ленина ул", 12 => nil)
    expect(paths(:houses, "full_mun_path")[10]).to eq("Кировская обл, город Киров г.о., Киров г, Ленина ул, д. 10")
  end

  it "заполняет tsvector путей и строит полнотекстовые индексы" do
    builder.build

    found = db_connection.exec("SELECT id FROM #{schema}.houses WHERE full_adm_path_tsv @@ plainto_tsquery('russian', 'Ленина')")
    expect(found.column_values(0)).to contain_exactly("10", "11")
    indexes = db_connection.exec_params("SELECT indexname FROM pg_indexes WHERE schemaname = $1", [schema]).column_values(0)
    expect(indexes).to contain_exactly("idx_address_objects_full_adm_path_tsv", "idx_address_objects_full_mun_path_tsv",
                                       "idx_houses_full_adm_path_tsv", "idx_houses_full_mun_path_tsv")
  end

  it "даёт тот же результат при любом размере батча" do
    builder.build(batch_size: 1)

    expect(paths(:houses, "full_adm_path")[10]).to eq("Кировская обл, Киров г, Ленина ул, д. 10")
    expect(paths(:address_objects, "full_mun_path").compact.size).to eq(5)
  end

  it "сообщает прогресс по просмотренным записям и возвращает число записей с путём" do
    progress = []

    expect(builder.build(on_progress: ->(*args) { progress << args })).to eq(7)
    expect(progress.first).to eq([0, 8, :paths])
    expect(progress.last).to eq([8, 8, :paths])
  end

  it "заполняет только пустые пути: повторный запуск продолжает, а не пересобирает" do
    db_connection.exec("UPDATE #{schema}.houses SET full_adm_path = 'готово' WHERE id = 10")

    builder.build
    db_connection.exec("UPDATE #{schema}.address_objects SET name = 'Новая' WHERE id = 3")
    builder.build

    expect(paths(:houses, "full_adm_path")).to include(10 => "готово", 11 => "Кировская обл, Киров г, Ленина ул")
  end

  it "строит пути только по загруженным иерархиям" do
    db_connection.exec("DROP TABLE #{schema}.mun_hierarchy")

    builder.build

    expect(builder.hierarchies).to eq([:adm])
    expect(paths(:houses, "full_mun_path").values.uniq).to eq([nil])
    expect(db_connection.exec_params("SELECT indexname FROM pg_indexes WHERE schemaname = $1", [schema]).column_values(0))
      .to contain_exactly("idx_address_objects_full_adm_path_tsv", "idx_houses_full_adm_path_tsv")
  end

  it "ничего не строит без адресных объектов" do
    db_connection.exec("DROP TABLE #{schema}.address_objects")

    expect(builder.build).to eq(0)
  end
end
