defmodule MCP.Protocol.Types.ResourceTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Types.Resource

  @resource_map %{
    "uri" => "file:///project/readme.md",
    "name" => "readme",
    "title" => "README",
    "description" => "Project readme file",
    "mimeType" => "text/markdown"
  }

  describe "from_map/1" do
    test "parses a resource with all fields" do
      resource = Resource.from_map(@resource_map)

      assert resource.uri == "file:///project/readme.md"
      assert resource.name == "readme"
      assert resource.title == "README"
      assert resource.mime_type == "text/markdown"
    end

    test "parses a resource with annotations" do
      map =
        Map.put(@resource_map, "annotations", %{
          "audience" => ["user"],
          "lastModified" => "2026-01-01T00:00:00Z"
        })

      resource = Resource.from_map(map)
      assert resource.annotations.audience == ["user"]
      assert resource.annotations.last_modified == "2026-01-01T00:00:00Z"
    end

    test "parses a resource with size" do
      map = Map.put(@resource_map, "size", 1024)
      resource = Resource.from_map(map)
      assert resource.size == 1024
    end
  end

  describe "JSON encoding" do
    test "round-trips with camelCase keys" do
      resource = Resource.from_map(@resource_map)
      json = Jason.encode!(resource)
      decoded = Jason.decode!(json)

      assert decoded["uri"] == "file:///project/readme.md"
      assert decoded["mimeType"] == "text/markdown"
      refute Map.has_key?(decoded, "mime_type")
    end
  end
end
