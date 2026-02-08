defmodule MCP.Protocol.Messages.ToolsTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Messages.Tools

  describe "ListParams" do
    test "from_map/1 parses with cursor" do
      params = Tools.ListParams.from_map(%{"cursor" => "page2"})
      assert params.cursor == "page2"
    end

    test "from_map/1 handles empty map" do
      params = Tools.ListParams.from_map(%{})
      assert params.cursor == nil
    end

    test "to_map/1 omits nil cursor" do
      params = %Tools.ListParams{cursor: nil}
      assert Tools.ListParams.to_map(params) == %{}
    end

    test "to_map/1 includes cursor" do
      params = %Tools.ListParams{cursor: "abc"}
      assert Tools.ListParams.to_map(params) == %{"cursor" => "abc"}
    end
  end

  describe "ListResult" do
    test "from_map/1 parses tool list" do
      map = %{
        "tools" => [
          %{
            "name" => "weather",
            "inputSchema" => %{"type" => "object"}
          }
        ],
        "nextCursor" => "page2"
      }

      result = Tools.ListResult.from_map(map)

      assert length(result.tools) == 1
      assert hd(result.tools).name == "weather"
      assert result.next_cursor == "page2"
    end

    test "round-trips through JSON" do
      map = %{
        "tools" => [
          %{"name" => "t1", "inputSchema" => %{"type" => "object"}}
        ]
      }

      result = Tools.ListResult.from_map(map)
      json = Jason.encode!(result)
      decoded = Jason.decode!(json)

      assert length(decoded["tools"]) == 1
      assert hd(decoded["tools"])["name"] == "t1"
      refute Map.has_key?(decoded, "nextCursor")
    end
  end

  describe "CallParams" do
    test "from_map/1 parses call params" do
      params =
        Tools.CallParams.from_map(%{"name" => "weather", "arguments" => %{"city" => "NYC"}})

      assert params.name == "weather"
      assert params.arguments == %{"city" => "NYC"}
    end

    test "to_map/1 omits nil arguments" do
      params = %Tools.CallParams{name: "ping"}
      map = Tools.CallParams.to_map(params)
      assert map == %{"name" => "ping"}
    end
  end

  describe "CallResult" do
    test "from_map/1 parses call result" do
      map = %{
        "content" => [%{"type" => "text", "text" => "72F, sunny"}],
        "isError" => false
      }

      result = Tools.CallResult.from_map(map)
      assert length(result.content) == 1
      assert hd(result.content).text == "72F, sunny"
      assert result.is_error == false
    end

    test "from_map/1 parses with structuredContent" do
      map = %{
        "content" => [%{"type" => "text", "text" => "result"}],
        "structuredContent" => %{"temperature" => 72}
      }

      result = Tools.CallResult.from_map(map)
      assert result.structured_content == %{"temperature" => 72}
    end

    test "round-trips through JSON with camelCase" do
      map = %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "structuredContent" => %{"val" => 1},
        "isError" => true
      }

      result = Tools.CallResult.from_map(map)
      json = Jason.encode!(result)
      decoded = Jason.decode!(json)

      assert decoded["structuredContent"] == %{"val" => 1}
      assert decoded["isError"] == true
    end
  end
end
