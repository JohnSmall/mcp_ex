defmodule MCP.Protocol.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Capabilities.{ClientCapabilities, ServerCapabilities}

  describe "ServerCapabilities" do
    test "from_map/1 parses full capabilities" do
      map = %{
        "tools" => %{"listChanged" => true},
        "resources" => %{"subscribe" => true, "listChanged" => true},
        "prompts" => %{"listChanged" => true},
        "logging" => %{},
        "completions" => %{}
      }

      caps = ServerCapabilities.from_map(map)

      assert caps.tools.list_changed == true
      assert caps.resources.subscribe == true
      assert caps.resources.list_changed == true
      assert caps.prompts.list_changed == true
      assert %MCP.Protocol.Capabilities.LoggingCapabilities{} = caps.logging
      assert %MCP.Protocol.Capabilities.CompletionCapabilities{} = caps.completions
    end

    test "from_map/1 handles missing capabilities" do
      caps = ServerCapabilities.from_map(%{})

      assert caps.tools == nil
      assert caps.resources == nil
      assert caps.prompts == nil
      assert caps.logging == nil
      assert caps.completions == nil
    end

    test "from_map/1 handles experimental capabilities" do
      map = %{"experimental" => %{"custom" => %{"enabled" => true}}}
      caps = ServerCapabilities.from_map(map)
      assert caps.experimental == %{"custom" => %{"enabled" => true}}
    end

    test "round-trips through JSON" do
      map = %{
        "tools" => %{"listChanged" => true},
        "resources" => %{"subscribe" => true}
      }

      caps = ServerCapabilities.from_map(map)
      json = Jason.encode!(caps)
      decoded = Jason.decode!(json)

      assert decoded["tools"]["listChanged"] == true
      assert decoded["resources"]["subscribe"] == true
      refute Map.has_key?(decoded, "prompts")
      refute Map.has_key?(decoded, "logging")
    end
  end

  describe "ClientCapabilities" do
    test "from_map/1 parses full capabilities" do
      map = %{
        "roots" => %{"listChanged" => true},
        "sampling" => %{},
        "elicitation" => %{"form" => %{}, "url" => %{}}
      }

      caps = ClientCapabilities.from_map(map)

      assert caps.roots.list_changed == true
      assert %MCP.Protocol.Capabilities.SamplingCapabilities{} = caps.sampling
      assert caps.elicitation.form == %{}
      assert caps.elicitation.url == %{}
    end

    test "from_map/1 handles empty map" do
      caps = ClientCapabilities.from_map(%{})

      assert caps.roots == nil
      assert caps.sampling == nil
      assert caps.elicitation == nil
    end

    test "round-trips through JSON" do
      map = %{
        "roots" => %{"listChanged" => true},
        "sampling" => %{}
      }

      caps = ClientCapabilities.from_map(map)
      json = Jason.encode!(caps)
      decoded = Jason.decode!(json)

      assert decoded["roots"]["listChanged"] == true
      assert decoded["sampling"] == %{}
      refute Map.has_key?(decoded, "elicitation")
    end
  end
end
