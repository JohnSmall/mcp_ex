defmodule MCP.Protocol.Messages.ResourcesTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Messages.Resources

  describe "ListResult" do
    test "from_map/1 parses resource list" do
      map = %{
        "resources" => [
          %{"uri" => "file:///a.txt", "name" => "a"}
        ]
      }

      result = Resources.ListResult.from_map(map)
      assert length(result.resources) == 1
      assert hd(result.resources).uri == "file:///a.txt"
    end
  end

  describe "ReadResult" do
    test "from_map/1 parses read result with text content" do
      map = %{
        "contents" => [
          %{"uri" => "file:///a.txt", "text" => "hello world"}
        ]
      }

      result = Resources.ReadResult.from_map(map)
      assert length(result.contents) == 1
      assert hd(result.contents).text == "hello world"
    end

    test "from_map/1 parses read result with blob content" do
      map = %{
        "contents" => [
          %{
            "uri" => "file:///a.bin",
            "blob" => "base64data==",
            "mimeType" => "application/octet-stream"
          }
        ]
      }

      result = Resources.ReadResult.from_map(map)
      assert hd(result.contents).blob == "base64data=="
      assert hd(result.contents).mime_type == "application/octet-stream"
    end
  end

  describe "ListTemplatesResult" do
    test "from_map/1 parses template list" do
      map = %{
        "resourceTemplates" => [
          %{
            "uriTemplate" => "file:///logs/{date}.log",
            "name" => "logs",
            "mimeType" => "text/plain"
          }
        ]
      }

      result = Resources.ListTemplatesResult.from_map(map)
      assert length(result.resource_templates) == 1
      assert hd(result.resource_templates).uri_template == "file:///logs/{date}.log"
    end

    test "round-trips through JSON with camelCase" do
      map = %{
        "resourceTemplates" => [
          %{"uriTemplate" => "file:///{name}", "name" => "files"}
        ],
        "nextCursor" => "page2"
      }

      result = Resources.ListTemplatesResult.from_map(map)
      json = Jason.encode!(result)
      decoded = Jason.decode!(json)

      assert decoded["resourceTemplates"] |> hd() |> Map.get("uriTemplate") == "file:///{name}"
      assert decoded["nextCursor"] == "page2"
    end
  end

  describe "SubscribeParams" do
    test "from_map/1 parses subscribe params" do
      params = Resources.SubscribeParams.from_map(%{"uri" => "file:///a.txt"})
      assert params.uri == "file:///a.txt"
    end
  end
end
