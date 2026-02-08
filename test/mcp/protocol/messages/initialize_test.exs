defmodule MCP.Protocol.Messages.InitializeTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.Messages.Initialize

  @init_params_map %{
    "protocolVersion" => "2025-11-25",
    "capabilities" => %{
      "roots" => %{"listChanged" => true},
      "sampling" => %{}
    },
    "clientInfo" => %{
      "name" => "test-client",
      "version" => "1.0.0"
    }
  }

  @init_result_map %{
    "protocolVersion" => "2025-11-25",
    "capabilities" => %{
      "tools" => %{"listChanged" => true},
      "resources" => %{"subscribe" => true}
    },
    "serverInfo" => %{
      "name" => "test-server",
      "version" => "2.0.0"
    },
    "instructions" => "Use tools carefully"
  }

  describe "Initialize.Params" do
    test "from_map/1 parses initialize params" do
      params = Initialize.Params.from_map(@init_params_map)

      assert params.protocol_version == "2025-11-25"
      assert params.capabilities.roots.list_changed == true
      assert params.client_info.name == "test-client"
      assert params.client_info.version == "1.0.0"
    end

    test "to_map/1 produces wire format" do
      params = Initialize.Params.from_map(@init_params_map)
      map = Initialize.Params.to_map(params)

      assert map["protocolVersion"] == "2025-11-25"
      assert map["clientInfo"]["name"] == "test-client"
      assert map["capabilities"]["roots"]["listChanged"] == true
    end
  end

  describe "Initialize.Result" do
    test "from_map/1 parses initialize result" do
      result = Initialize.Result.from_map(@init_result_map)

      assert result.protocol_version == "2025-11-25"
      assert result.capabilities.tools.list_changed == true
      assert result.server_info.name == "test-server"
      assert result.instructions == "Use tools carefully"
    end

    test "from_map/1 handles missing optional fields" do
      map = Map.delete(@init_result_map, "instructions")
      result = Initialize.Result.from_map(map)
      assert result.instructions == nil
    end

    test "to_map/1 produces wire format" do
      result = Initialize.Result.from_map(@init_result_map)
      map = Initialize.Result.to_map(result)

      assert map["protocolVersion"] == "2025-11-25"
      assert map["serverInfo"]["name"] == "test-server"
      assert map["instructions"] == "Use tools carefully"
    end
  end
end
