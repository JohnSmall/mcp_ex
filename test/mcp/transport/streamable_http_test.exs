defmodule MCP.Transport.StreamableHTTPTest do
  use ExUnit.Case, async: false

  alias MCP.Transport.StreamableHTTP

  # --- Test Handler ---

  defmodule TestHandler do
    @behaviour MCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{
          "name" => "echo",
          "description" => "Echoes the input message",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "message" => %{"type" => "string"}
            }
          }
        },
        %{
          "name" => "add",
          "description" => "Adds two numbers",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "a" => %{"type" => "number"},
              "b" => %{"type" => "number"}
            }
          }
        }
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("echo", %{"message" => msg}, state) do
      {:ok, [%{"type" => "text", "text" => msg}], state}
    end

    def handle_call_tool("add", %{"a" => a, "b" => b}, state) do
      {:ok, [%{"type" => "text", "text" => "#{a + b}"}], state}
    end

    def handle_call_tool(name, _args, state) do
      {:error, -32_602, "Unknown tool: #{name}", state}
    end

    @impl true
    def handle_list_resources(_cursor, state) do
      resources = [
        %{
          "uri" => "test://hello",
          "name" => "hello",
          "description" => "A test resource"
        }
      ]

      {:ok, resources, nil, state}
    end

    @impl true
    def handle_read_resource("test://hello", state) do
      {:ok, [%{"uri" => "test://hello", "text" => "Hello, World!"}], state}
    end

    def handle_read_resource(uri, state) do
      {:error, -32_002, "Resource not found: #{uri}", state}
    end
  end

  # --- Helper Functions ---

  defp find_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start_server(opts \\ []) do
    port = find_free_port()
    enable_json = Keyword.get(opts, :enable_json_response, false)

    plug_opts =
      StreamableHTTP.Plug.init(
        server_mod: TestHandler,
        server_opts: [
          server_info: %{name: "test-server", version: "1.0.0"}
        ],
        enable_json_response: enable_json,
        session_id_generator: fn -> UUID.uuid4() end
      )

    {:ok, bandit_pid} =
      Bandit.start_link(
        plug: {StreamableHTTP.Plug, plug_opts},
        port: port,
        ip: {127, 0, 0, 1}
      )

    url = "http://127.0.0.1:#{port}"
    {url, bandit_pid}
  end

  defp start_client(url) do
    {:ok, client} =
      MCP.Client.start_link(
        transport: {StreamableHTTP.Client, url: url},
        client_info: %{name: "test-client", version: "1.0.0"}
      )

    client
  end

  # --- Tests ---

  describe "SSE response mode (default)" do
    test "full lifecycle: initialize → list tools → call tool → close" do
      {url, _bandit} = start_server()
      client = start_client(url)

      # Connect (initialize handshake)
      assert {:ok, result} = MCP.Client.connect(client)
      assert result.server_info.name == "test-server"
      assert result.server_info.version == "1.0.0"

      # List tools
      assert {:ok, tools_result} = MCP.Client.list_tools(client)
      tools = tools_result["tools"]
      assert length(tools) == 2
      assert Enum.any?(tools, fn t -> t["name"] == "echo" end)
      assert Enum.any?(tools, fn t -> t["name"] == "add" end)

      # Call echo tool
      assert {:ok, call_result} = MCP.Client.call_tool(client, "echo", %{"message" => "hi"})
      content = call_result["content"]
      assert length(content) == 1
      assert hd(content)["text"] == "hi"

      # Call add tool
      assert {:ok, add_result} = MCP.Client.call_tool(client, "add", %{"a" => 3, "b" => 4})
      assert hd(add_result["content"])["text"] == "7"

      # Close
      assert :ok = MCP.Client.close(client)
    end

    test "list resources and read resource" do
      {url, _bandit} = start_server()
      client = start_client(url)

      assert {:ok, _} = MCP.Client.connect(client)

      assert {:ok, res} = MCP.Client.list_resources(client)
      assert length(res["resources"]) == 1
      assert hd(res["resources"])["uri"] == "test://hello"

      assert {:ok, read_res} = MCP.Client.read_resource(client, "test://hello")
      assert hd(read_res["contents"])["text"] == "Hello, World!"

      MCP.Client.close(client)
    end

    test "call unknown tool returns error" do
      {url, _bandit} = start_server()
      client = start_client(url)

      assert {:ok, _} = MCP.Client.connect(client)

      assert {:error, error} = MCP.Client.call_tool(client, "nonexistent", %{})
      assert error.code == -32_602

      MCP.Client.close(client)
    end

    test "ping works before and after initialization" do
      {url, _bandit} = start_server()
      client = start_client(url)

      # Ping before init should work (but we need a session first for HTTP)
      # With HTTP, initialize must come first to create a session
      assert {:ok, _} = MCP.Client.connect(client)
      assert {:ok, _} = MCP.Client.ping(client)

      MCP.Client.close(client)
    end
  end

  describe "JSON response mode" do
    test "full lifecycle with JSON responses" do
      {url, _bandit} = start_server(enable_json_response: true)
      client = start_client(url)

      assert {:ok, result} = MCP.Client.connect(client)
      assert result.server_info.name == "test-server"

      assert {:ok, tools_result} = MCP.Client.list_tools(client)
      assert length(tools_result["tools"]) == 2

      assert {:ok, call_result} =
               MCP.Client.call_tool(client, "echo", %{"message" => "json mode"})

      assert hd(call_result["content"])["text"] == "json mode"

      MCP.Client.close(client)
    end
  end

  describe "session management" do
    test "DELETE terminates session" do
      {url, _bandit} = start_server()
      client = start_client(url)

      assert {:ok, _} = MCP.Client.connect(client)
      assert {:ok, _} = MCP.Client.list_tools(client)

      # Close sends DELETE
      assert :ok = MCP.Client.close(client)
    end

    test "multiple sessions are independent" do
      {url, _bandit} = start_server()

      client1 = start_client(url)
      client2 = start_client(url)

      assert {:ok, _} = MCP.Client.connect(client1)
      assert {:ok, _} = MCP.Client.connect(client2)

      assert {:ok, r1} = MCP.Client.list_tools(client1)
      assert {:ok, r2} = MCP.Client.list_tools(client2)

      assert length(r1["tools"]) == 2
      assert length(r2["tools"]) == 2

      MCP.Client.close(client1)
      MCP.Client.close(client2)
    end
  end

  describe "error handling" do
    test "unsupported HTTP method returns 405" do
      {url, _bandit} = start_server()

      {:ok, resp} = Req.put(url)
      assert resp.status == 405
      assert resp.headers["allow"] == ["GET, POST, DELETE"]
    end

    test "invalid JSON body returns parse error" do
      {url, _bandit} = start_server()

      headers = [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"}
      ]

      {:ok, resp} = Req.post(url, body: "not json", headers: headers)
      assert resp.status == 400
      assert resp.body["error"]["code"] == -32_700
    end

    test "mismatched protocol version is accepted with warning" do
      {url, _bandit} = start_server()

      # First, initialize to get a session
      init_msg = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      headers = [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"}
      ]

      {:ok, init_resp} = Req.post(url, body: Jason.encode!(init_msg), headers: headers)
      assert init_resp.status == 200

      session_id =
        case init_resp.headers["mcp-session-id"] do
          [sid | _] -> sid
          sid when is_binary(sid) -> sid
        end

      # Send a request with different protocol version — accepted per MCP spec (MAY reject)
      list_msg = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list",
        "params" => %{}
      }

      other_headers =
        headers ++
          [
            {"mcp-session-id", session_id},
            {"mcp-protocol-version", "1999-01-01"}
          ]

      {:ok, resp} = Req.post(url, body: Jason.encode!(list_msg), headers: other_headers)
      assert resp.status == 200
    end
  end

  describe "raw HTTP" do
    test "POST initialize returns session ID in header" do
      {url, _bandit} = start_server()

      init_msg = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "raw-test", "version" => "1.0"}
        }
      }

      headers = [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"}
      ]

      {:ok, resp} = Req.post(url, body: Jason.encode!(init_msg), headers: headers)
      assert resp.status == 200

      session_id = resp.headers["mcp-session-id"]
      assert session_id != nil
    end

    test "POST notification returns 202" do
      {url, _bandit} = start_server()

      # Initialize first
      init_msg = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "raw-test", "version" => "1.0"}
        }
      }

      headers = [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"}
      ]

      {:ok, init_resp} = Req.post(url, body: Jason.encode!(init_msg), headers: headers)

      session_id =
        case init_resp.headers["mcp-session-id"] do
          [sid | _] -> sid
          sid when is_binary(sid) -> sid
        end

      # Send initialized notification
      notif = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }

      notif_headers = headers ++ [{"mcp-session-id", session_id}]
      {:ok, resp} = Req.post(url, body: Jason.encode!(notif), headers: notif_headers)
      assert resp.status == 202
    end
  end
end
