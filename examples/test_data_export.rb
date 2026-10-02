#!/usr/bin/env ruby
# frozen_string_literal: true

require "gar"

def escape_sql_value(value)
  return "NULL" if value.nil?

  value.to_s.gsub("'", "''").gsub("\\", "\\\\")
end

def write_sql_insert(file, table_name, records)
  return if records.empty?

  columns = records.first.keys
  column_names = columns.map { "\"#{_1}\"" }.join(", ")

  file.puts "-- #{table_name.upcase} DATA"
  file.puts "INSERT INTO gar.#{table_name} (#{column_names}) VALUES"

  records.each_with_index do |record, index|
    values =
      columns.map do |col|
        value = record[col.to_s]

        if value.nil?
          "NULL"
        elsif value.is_a?(String)
          "'#{escape_sql_value(value)}'"
        else
          value.to_s
        end
      end

    file.puts "#{',' unless index.zero?}(#{values.join(', ')})"
  end

  file.puts ";"
  file.puts
end

def export_test_data
  db_conn     = Gar::Database.create_connection
  schema_name = Gar.configuration.database_schema

  puts "Exporting test data from GAR database..."
  puts "=" * 50

  # Initialize counters
  stats = {}

  File.open("spec/fixtures/data.sql", "w") do |file|
    file.puts "-- GAR Test Data SQL Dump"
    file.puts "-- Run with: ruby examples/test_data_export.rb"
    file.puts

    # Export related address_object_types
    puts "Exporting related address_object_types..."
    address_object_types = db_conn.exec(<<-SQL).to_a
      SELECT *
      FROM #{schema_name}.address_object_types
    SQL

    stats[:address_object_types] = address_object_types.size
    write_sql_insert(file, "address_object_types", address_object_types)

    # Export related house_types
    puts "Exporting related house_types..."
    house_types = db_conn.exec(<<-SQL).to_a
      SELECT  *
      FROM #{schema_name}.house_types
    SQL

    stats[:house_types] = house_types.size
    write_sql_insert(file, "house_types", house_types)

    # Export random address_objects with full paths
    puts "Exporting random address_objects (regions, cities, streets)..."
    address_objects = db_conn.exec(<<-SQL).to_a
      SELECT *
      FROM #{schema_name}.address_objects
      WHERE full_adm_path IS NOT NULL
      ORDER BY RANDOM()
      LIMIT 100
    SQL

    stats[:address_objects] = address_objects.size
    write_sql_insert(file, "address_objects", address_objects)

    # Export random houses with full paths
    puts "Exporting random houses..."
    houses = db_conn.exec(<<-SQL).to_a
      SELECT *
      FROM #{schema_name}.houses
      WHERE full_adm_path IS NOT NULL
      ORDER BY RANDOM()
      LIMIT 100
    SQL

    stats[:houses] = houses.size
    write_sql_insert(file, "houses", houses)

    # Get object_ids for hierarchy tables from the exported records
    object_ids = (houses + address_objects).map { _1["object_id"] }.uniq.join(",")

    # Export related adm_hierarchy records
    puts "Exporting related adm_hierarchy records..."
    adm_hierarchy = db_conn.exec(<<-SQL).to_a
      SELECT *
      FROM #{schema_name}.adm_hierarchy
      WHERE object_id IN (#{object_ids})
      ORDER BY object_id
      LIMIT 5000
    SQL

    stats[:adm_hierarchy] = adm_hierarchy.size
    write_sql_insert(file, "adm_hierarchy", adm_hierarchy)

    # Export related mun_hierarchy records
    puts "Exporting related mun_hierarchy records..."
    mun_hierarchy = db_conn.exec(<<-SQL).to_a
      SELECT *
      FROM #{schema_name}.mun_hierarchy
      WHERE object_id IN (#{object_ids})
      ORDER BY object_id
      LIMIT 5000
    SQL

    stats[:mun_hierarchy] = mun_hierarchy.size
    write_sql_insert(file, "mun_hierarchy", mun_hierarchy)
  end

  puts "Test data exported to spec/fixtures/data.sql"
  puts "Address objects: #{stats[:address_objects]}"
  puts "Houses: #{stats[:houses]}"
  puts "Address object types: #{stats[:address_object_types]}"
  puts "House types: #{stats[:house_types]}"
  puts "ADM hierarchy records: #{stats[:adm_hierarchy]}"
  puts "MUN hierarchy records: #{stats[:mun_hierarchy]}"
  puts ""
end

if __FILE__ == $PROGRAM_NAME
  begin
    export_test_data
  rescue StandardError => e
    puts "Error: #{e.message}"
  end
end
