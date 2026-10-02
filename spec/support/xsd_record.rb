# frozen_string_literal: true

require "ox"

# Запись из XSD ФНС: элемент и его атрибуты с базовым типом и ограничениями
module XsdRecord
  module_function

  DIR = File.expand_path("../../docs/xml_schema", __dir__)

  # Справочник доп. типов домов описан той же схемой, что и типы домов; все *_PARAMS — схемой AS_PARAM
  def path(table)
    key   = table.params? ? "PARAM" : table.file.sub("ADDHOUSE_TYPES", "HOUSE_TYPES")
    paths = Dir[File.join(DIR, "AS_#{key}_{2_,}251_*.xsd")]
    raise "Для #{table.name} нужна ровно одна XSD, найдено: #{paths}" unless paths.size == 1

    paths.first
  end

  def read(table)
    top        = children(Ox.load_file(path(table), mode: :generic).root, "xs:element")
    item       = children(find(top.first, "xs:sequence"), "xs:element").first
    definition = item[:ref] ? top.find { _1[:name] == item[:ref] } : item
    attributes = children(find(definition, "xs:complexType"), "xs:attribute").to_h { [_1[:name], type_of(_1)] }
    [item[:name] || item[:ref], attributes]
  end

  def type_of(attribute)
    restriction = find(attribute, "xs:restriction")
    facets      = (restriction&.nodes || []).group_by { _1.name.delete_prefix("xs:") }.transform_values { |nodes| nodes.map { _1[:value] } }
    { base: attribute[:type] || restriction&.[](:base), facets: }
  end

  def children(node, name) = node.nodes.select { _1.is_a?(Ox::Element) && _1.name == name }

  def find(node, name)
    node.nodes.each do |child|
      next unless child.is_a?(Ox::Element)
      return child if child.name == name

      found = find(child, name)
      return found if found
    end
    nil
  end

  # Совместим ли тип колонки с типом атрибута XSD
  def compatible?(type, base:, facets:)
    case type
    when :date    then base == "xs:date"
    when :boolean then base == "xs:boolean" || facets["enumeration"] == ["0", "1"]
    when :uuid    then facets["length"] == ["36"]
    when :bigint  then numeric?(base, facets)
    when :integer then numeric?(base, facets) && !wide?(base, facets)
    when :text    then base.nil? || base == "xs:string"
    end
  end

  # Число, в том числе строка из цифр (LEVEL в AS_ADDR_OBJ, OPERTYPEID в AS_STEADS)
  def numeric?(base, facets)
    ["xs:long", "xs:integer"].include?(base) || facets.fetch("pattern", []).any? { _1.start_with?("[0-9]") }
  end

  # Не помещается в integer: xs:long без ограничения разрядов или больше 10 цифр
  def wide?(base, facets)
    digits = facets.fetch("totalDigits", []).first
    digits ? digits.to_i > 10 : base == "xs:long"
  end
end
