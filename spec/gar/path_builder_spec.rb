# frozen_string_literal: true

RSpec.describe Gar::PathBuilder, :db do
  let(:schema)  { isolated_schema("gar_paths") }
  let(:builder) { described_class.new(db_connection, schema:) }

  # Область 1 → город 2 → улица 3 (adm); в муниципальной иерархии город — через округ 4.
  # Дома: 10 на улице, 11 без номера, 12 без строки в иерархии, 13 с корпусом и строением
  def create_tables(*names)
    db_connection.exec("CREATE SCHEMA #{schema}")
    names.each { db_connection.exec(Gar::Schema.fetch(_1).create_sql(schema)) }
  end

  def insert(table, columns, *rows)
    placeholders = columns.each_index.map { "$#{_1 + 1}" }.join(", ")
    rows.each { db_connection.exec_params("INSERT INTO #{schema}.#{table} (#{columns.join(', ')}) VALUES (#{placeholders})", _1) }
  end

  # Строки иерархии: OBJECTID → PATH, родитель — предпоследний элемент пути
  def hierarchy(table, paths)
    insert(table, [:id, :object_id, :parent_obj_id, :path, :is_active],
           *paths.each_with_index.map { |(object_id, path), id| [id + 1, object_id, path.split(".")[-2], path, true] })
  end

  def paths(table, column)
    db_connection.exec("SELECT id, #{column} FROM #{schema}.#{table} ORDER BY id").to_h { [_1["id"].to_i, _1[column]] }
  end

  before do
    create_tables(:address_objects, :houses, :house_types, :add_house_types, :adm_hierarchy, :mun_hierarchy)
    columns = [:id, :object_id, :name, :type_name, :is_actual, :is_active]
    insert(:address_objects, columns,
           [1, 1, "Кировская", "обл", true, true], [2, 2, "Киров", "г", true, true], [3, 3, "Ленина", "ул", true, true],
           [4, 4, "город Киров", "г.о.", true, true],
           [5, 3, "Старая", "ул", false, false]) # историческая запись улицы не попадает в пути
    insert(:house_types, [:id, :short_name], [2, "д."])
    insert(:add_house_types, [:id, :short_name], [1, "к."], [2, "стр."])
    insert(:houses, [:id, :object_id, :house_num, :house_type, :add_num1, :add_type1, :add_num2, :add_type2, :is_actual, :is_active],
           [10, 10, "10", 2, nil, nil, nil, nil, true, true], [11, 11, nil, 2, nil, nil, nil, nil, true, true],
           [12, 12, "12", 2, nil, nil, nil, nil, true, true], [13, 13, "14 А", 2, "1", 1, "3", 2, true, true])
    hierarchy(:adm_hierarchy, 1 => "1", 2 => "1.2", 3 => "1.2.3", 10 => "1.2.3.10", 11 => "1.2.3.11", 13 => "1.2.3.13")
    hierarchy(:mun_hierarchy, 1 => "1", 4 => "1.4", 2 => "1.4.2", 3 => "1.4.2.3", 10 => "1.4.2.3.10")
  end

  it "строит административные и муниципальные пути по актуальным записям" do
    builder.build

    expect(paths(:address_objects, "full_adm_path")).to include(3 => "Кировская обл, Киров г, Ленина ул", 4 => nil)
    expect(paths(:address_objects, "full_mun_path")).to include(3 => "Кировская обл, город Киров г.о., Киров г, Ленина ул")
    expect(paths(:houses, "full_adm_path")).to eq(10 => "Кировская обл, Киров г, Ленина ул, д. 10",
                                                  11 => "Кировская обл, Киров г, Ленина ул", 12 => nil,
                                                  13 => "Кировская обл, Киров г, Ленина ул, д. 14 А к. 1 стр. 3")
    expect(paths(:houses, "full_mun_path")[10]).to eq("Кировская обл, город Киров г.о., Киров г, Ленина ул, д. 10")
  end

  it "считает дома в поддереве по обеим иерархиям и отмечает административные центры" do
    db_connection.exec(Gar::Schema.fetch(:addr_obj_params).create_sql(schema))
    insert(:addr_obj_params, [:id, :object_id, :type_id, :value], [1, 2, 22, "1"], [2, 3, 5, "610000"])

    builder.build

    expect(paths(:address_objects, "house_count")).to include(1 => "3", 2 => "3", 3 => "3", 4 => "1")
    expect(paths(:address_objects, "is_capital")).to include(1 => nil, 2 => "t", 3 => nil)

    db_connection.exec("UPDATE #{schema}.houses SET is_active = false WHERE id <> 10; DELETE FROM #{schema}.addr_obj_params")
    builder.build
    expect(paths(:address_objects, "house_count")).to include(1 => "1", 4 => "1")
    expect(paths(:address_objects, "is_capital")[2]).to be_nil
  end

  it "заполняет tsvector путей и строит полнотекстовые индексы" do
    builder.build

    found = db_connection.exec("SELECT id FROM #{schema}.houses WHERE full_adm_path_tsv @@ plainto_tsquery('russian', 'Ленина')")
    expect(found.column_values(0)).to contain_exactly("10", "11", "13")
    indexes = db_connection.exec_params("SELECT indexname FROM pg_indexes WHERE schemaname = $1", [schema]).column_values(0)
    expected =
      [:address_objects, :houses].product([:adm, :mun]).flat_map do |table, hierarchy|
        ["idx_#{table}_full_#{hierarchy}_path_tsv", "idx_#{table}_#{hierarchy}_path_ids"]
      end
    expect(indexes).to match_array(expected)
  end

  it "сохраняет OBJECTID объектов пути от корня до самого объекта" do
    builder.build

    expect(paths(:houses, "adm_path_ids")).to include(10 => "{1,2,3,10}", 12 => nil)
    expect(paths(:houses, "mun_path_ids")[10]).to eq("{1,4,2,3,10}")
    within_city = db_connection.exec("SELECT id FROM #{schema}.houses WHERE adm_path_ids @> ARRAY[2::bigint] ORDER BY id")
    expect(within_city.column_values(0)).to eq(["10", "11", "13"])
  end

  it "хранит номер дома для сравнения: без пробелов, в нижнем регистре" do
    expect(paths(:houses, "house_num_norm")).to include(10 => "10", 11 => nil, 13 => "14а")
  end

  it "пересобирает пути объекта и всех его потомков после invalidate" do
    builder.build
    db_connection.exec("UPDATE #{schema}.address_objects SET name = 'Новая' WHERE object_id = 3 AND is_actual")

    expect(builder.invalidate([3])).to eq(5) # обе записи улицы и три дома
    builder.build

    expect(paths(:houses, "full_adm_path")[10]).to eq("Кировская обл, Киров г, Новая ул, д. 10")
    expect(paths(:address_objects, "full_mun_path")[3]).to eq("Кировская обл, город Киров г.о., Киров г, Новая ул")
    expect(paths(:address_objects, "full_adm_path")[2]).to eq("Кировская обл, Киров г")
  end

  context "с импортированной схемой" do
    include_context "с синтетическим архивом"

    it "отмечает в gar_meta, что пути построены" do
      imported = Gar::Importer.new(db_connection).import_full_base(zip_path, schema: isolated_schema("gar_meta"))

      described_class.new(db_connection, schema: imported).build

      expect(Gar::Meta.read(db_connection, imported)).to have_attributes(status: "ready", paths_built_at: be_within(60).of(Time.now))
    end
  end

  it "даёт тот же результат при любом размере батча" do
    builder.build(batch_size: 1)

    expect(paths(:houses, "full_adm_path")[10]).to eq("Кировская обл, Киров г, Ленина ул, д. 10")
    expect(paths(:address_objects, "full_mun_path").compact.size).to eq(5)
    expect(paths(:houses, "full_adm_path")[13]).to eq("Кировская обл, Киров г, Ленина ул, д. 14 А к. 1 стр. 3")
  end

  it "сообщает прогресс по просмотренным записям и возвращает число записей с путём" do
    progress = []

    expect(builder.build(on_progress: ->(*args) { progress << args })).to eq(8)
    expect(progress.first).to eq([0, 9, :paths])
    expect(progress.last).to eq([9, 9, :paths])
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
      .to contain_exactly("idx_address_objects_full_adm_path_tsv", "idx_houses_full_adm_path_tsv",
                          "idx_address_objects_adm_path_ids", "idx_houses_adm_path_ids")
  end

  it "без адресных объектов или иерархий бросает ConfigurationError" do
    db_connection.exec("DROP TABLE #{schema}.adm_hierarchy, #{schema}.mun_hierarchy")
    expect { builder.build }.to raise_error(Gar::ConfigurationError, /нет ни одной иерархии/)

    db_connection.exec("DROP TABLE #{schema}.address_objects")
    expect { described_class.new(db_connection, schema:).build }.to raise_error(Gar::ConfigurationError, /нет адресных объектов/)
  end
end
