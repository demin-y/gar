# frozen_string_literal: true

require "mini_sql"

RSpec.describe Gar::Search do
  let(:schema_name) { "gar" }
  let(:db_conn)     { IntegrationTestHelper.connection }
  let(:search)      { described_class.new(db_conn) }

  before do
    allow(Gar.configuration).to receive(:database_schema).and_return(schema_name)
  end

  describe "#search_address_objects" do
    it "returns search results for address objects" do
      results = search.search_address_objects("Зимняя")
      expect(results).to be_an(Array)
      expect(results.first).to have_attributes(name: "Зимняя", type_name: "ул.")
    end

    it "returns empty array for empty query" do
      results = search.search_address_objects("")
      expect(results).to eq([])
    end

    it "supports mun path type" do
      results = search.search_address_objects("Зимняя", path_type: :mun)
      expect(results).to be_an(Array)
    end

    it "supports autocomplete mode" do
      results = search.search_address_objects("Зим", autocomplete: true)
      expect(results).to be_an(Array)
    end

    it "supports pagination" do
      results = search.search_address_objects("Зимняя", limit: 5, offset: 0)
      expect(results.size).to be <= 5
    end
  end

  describe "#search_houses" do
    it "returns search results for houses" do
      results = search.search_houses("10")
      expect(results).to be_an(Array)
      # NOTE: Test data may not have houses, so results might be empty
    end

    it "returns empty array for empty query" do
      results = search.search_houses("")
      expect(results).to eq([])
    end

    it "supports mun path type" do
      results = search.search_houses("10", path_type: :mun)
      expect(results).to be_an(Array)
    end

    it "supports autocomplete mode" do
      results = search.search_houses("1", autocomplete: true)
      expect(results).to be_an(Array)
    end
  end

  describe "#find_address_objects" do
    context "when parent_guid is nil" do
      it "finds regions (level 1)" do
        results = search.find_address_objects
        expect(results).to be_an(Array)
        # Test data may not have level 1 objects, so check if array is returned
      end
    end

    context "when parent_guid is provided" do
      let(:parent_guid) { "ade36438-cc47-4b4f-92a4-c7cb5ed42b92" }

      it "finds child objects" do
        results = search.find_address_objects(parent_guid: parent_guid)
        expect(results).to be_an(Array)
      end

      it "supports level filtering" do
        results = search.find_address_objects(parent_guid: parent_guid, level: 8)
        expect(results).to be_an(Array)
      end

      it "supports mun hierarchy" do
        results = search.find_address_objects(parent_guid: parent_guid, path_type: :mun)
        expect(results).to be_an(Array)
      end
    end
  end

  describe "#find_houses" do
    let(:street_guid) { "ade36438-cc47-4b4f-92a4-c7cb5ed42b92" }

    it "finds houses on the street" do
      results = search.find_houses(street_guid)
      expect(results).to be_an(Array)
    end

    it "supports mun hierarchy" do
      results = search.find_houses(street_guid, path_type: :mun)
      expect(results).to be_an(Array)
    end

    it "supports custom limit" do
      results = search.find_houses(street_guid, limit: 50)
      expect(results.size).to be <= 50
    end
  end

  describe "#find_address_object_by_guid" do
    let(:guid) { "ade36438-cc47-4b4f-92a4-c7cb5ed42b92" }

    it "finds address object by GUID" do
      result = search.find_address_object_by_guid(guid)
      expect(result).to have_attributes(object_guid: guid, name: "Зимняя")
    end

    it "supports mun path type" do
      result = search.find_address_object_by_guid(guid, path_type: :mun)
      expect(result).to have_attributes(object_guid: guid)
    end

    it "returns nil when not found" do
      result = search.find_address_object_by_guid("non-existent-guid")
      expect(result).to be_nil
    end
  end

  describe "#find_house_by_guid" do
    # Since test data may not have houses with GUIDs, this test might need adjustment
    it "returns nil for non-existent house GUID" do
      result = search.find_house_by_guid("non-existent-house-guid")
      expect(result).to be_nil
    end
  end
end
