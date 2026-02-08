defmodule MCP.Protocol.Types.ContentTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Types.Content

  alias MCP.Protocol.Types.Content.{
    AudioContent,
    EmbeddedResource,
    ImageContent,
    ResourceLink,
    TextContent
  }

  describe "TextContent" do
    test "from_map/1 parses text content" do
      map = %{"type" => "text", "text" => "Hello, world!"}
      content = Content.from_map(map)

      assert %TextContent{} = content
      assert content.type == "text"
      assert content.text == "Hello, world!"
    end

    test "from_map/1 parses text content with annotations" do
      map = %{
        "type" => "text",
        "text" => "Hello",
        "annotations" => %{"audience" => ["user"], "priority" => 0.8}
      }

      content = Content.from_map(map)
      assert content.annotations.audience == ["user"]
      assert content.annotations.priority == 0.8
    end

    test "round-trips through JSON" do
      original = %TextContent{text: "test"}
      json = Jason.encode!(original)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "text"
      assert decoded["text"] == "test"
      refute Map.has_key?(decoded, "annotations")
      refute Map.has_key?(decoded, "_meta")
    end
  end

  describe "ImageContent" do
    test "from_map/1 parses image content" do
      map = %{"type" => "image", "data" => "base64data==", "mimeType" => "image/png"}
      content = Content.from_map(map)

      assert %ImageContent{} = content
      assert content.data == "base64data=="
      assert content.mime_type == "image/png"
    end

    test "round-trips through JSON" do
      original = %ImageContent{data: "abc", mime_type: "image/jpeg"}
      json = Jason.encode!(original)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "image"
      assert decoded["data"] == "abc"
      assert decoded["mimeType"] == "image/jpeg"
    end
  end

  describe "AudioContent" do
    test "from_map/1 parses audio content" do
      map = %{"type" => "audio", "data" => "audiodata==", "mimeType" => "audio/wav"}
      content = Content.from_map(map)

      assert %AudioContent{} = content
      assert content.data == "audiodata=="
      assert content.mime_type == "audio/wav"
    end

    test "round-trips through JSON" do
      original = %AudioContent{data: "xyz", mime_type: "audio/mp3"}
      json = Jason.encode!(original)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "audio"
      assert decoded["mimeType"] == "audio/mp3"
    end
  end

  describe "EmbeddedResource" do
    test "from_map/1 parses embedded resource" do
      map = %{
        "type" => "resource",
        "resource" => %{
          "uri" => "file:///test.txt",
          "text" => "file contents"
        }
      }

      content = Content.from_map(map)

      assert %EmbeddedResource{} = content
      assert content.resource.uri == "file:///test.txt"
      assert content.resource.text == "file contents"
    end

    test "round-trips through JSON" do
      alias MCP.Protocol.Types.ResourceContents

      original = %EmbeddedResource{
        resource: %ResourceContents{uri: "file:///a.txt", text: "hello"}
      }

      json = Jason.encode!(original)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "resource"
      assert decoded["resource"]["uri"] == "file:///a.txt"
      assert decoded["resource"]["text"] == "hello"
    end
  end

  describe "ResourceLink" do
    test "from_map/1 parses resource link" do
      map = %{
        "type" => "resource_link",
        "uri" => "file:///docs/readme.md",
        "name" => "readme",
        "mimeType" => "text/markdown"
      }

      content = Content.from_map(map)

      assert %ResourceLink{} = content
      assert content.uri == "file:///docs/readme.md"
      assert content.name == "readme"
      assert content.mime_type == "text/markdown"
    end

    test "round-trips through JSON" do
      original = %ResourceLink{uri: "file:///a", name: "a", mime_type: "text/plain"}
      json = Jason.encode!(original)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "resource_link"
      assert decoded["uri"] == "file:///a"
      assert decoded["mimeType"] == "text/plain"
    end
  end
end
