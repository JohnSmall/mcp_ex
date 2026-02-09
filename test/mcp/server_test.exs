defmodule MCP.ServerTest do
  use ExUnit.Case, async: true

  alias MCP.Test.MockTransport

  # --- Test Handler ---

  defmodule TestHandler do
    @behaviour MCP.Server.Handler

    @impl true
    def init(opts) do
      {:ok,
       %{
         tools: Keyword.get(opts, :tools, []),
         resources: Keyword.get(opts, :resources, []),
         prompts: Keyword.get(opts, :prompts, []),
         subscriptions: [],
         log_level: nil
       }}
    end

    @impl true
    def handle_list_tools(nil, state) do
      {:ok, state.tools, nil, state}
    end

    def handle_list_tools("page2", state) do
      {:ok, [%{"name" => "tool_b"}], nil, state}
    end

    def handle_list_tools(_cursor, state) do
      {:ok, [], nil, state}
    end

    @impl true
    def handle_call_tool("echo", %{"message" => msg}, state) do
      content = [%{"type" => "text", "text" => msg}]
      {:ok, content, state}
    end

    def handle_call_tool("error_tool", _args, state) do
      {:ok, [%{"type" => "text", "text" => "something went wrong"}], true, state}
    end

    def handle_call_tool("fail_tool", _args, state) do
      {:error, -32_602, "Invalid params for fail_tool", state}
    end

    def handle_call_tool(_name, _args, state) do
      {:error, -32_601, "Unknown tool", state}
    end

    @impl true
    def handle_list_resources(_cursor, state) do
      {:ok, state.resources, nil, state}
    end

    @impl true
    def handle_read_resource("file://test.txt", state) do
      contents = [%{"uri" => "file://test.txt", "text" => "Hello, world!"}]
      {:ok, contents, state}
    end

    def handle_read_resource(uri, state) do
      {:error, -32_002, "Resource not found: #{uri}", state}
    end

    @impl true
    def handle_subscribe(uri, state) do
      {:ok, %{state | subscriptions: [uri | state.subscriptions]}}
    end

    @impl true
    def handle_unsubscribe(uri, state) do
      {:ok, %{state | subscriptions: List.delete(state.subscriptions, uri)}}
    end

    @impl true
    def handle_list_resource_templates(_cursor, state) do
      templates = [%{"uriTemplate" => "file:///{path}", "name" => "File"}]
      {:ok, templates, nil, state}
    end

    @impl true
    def handle_list_prompts(_cursor, state) do
      {:ok, state.prompts, nil, state}
    end

    @impl true
    def handle_get_prompt("greeting", _args, state) do
      result = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello!"}}
        ]
      }

      {:ok, result, state}
    end

    def handle_get_prompt(name, _args, state) do
      {:error, -32_601, "Unknown prompt: #{name}", state}
    end

    @impl true
    def handle_complete(_ref, %{"name" => "lang", "value" => prefix}, state) do
      completions =
        ~w(elixir erlang elm)
        |> Enum.filter(&String.starts_with?(&1, prefix))

      {:ok, %{"values" => completions, "hasMore" => false, "total" => length(completions)}, state}
    end

    def handle_complete(_ref, _argument, state) do
      {:ok, %{"values" => [], "hasMore" => false, "total" => 0}, state}
    end

    @impl true
    def handle_set_log_level(level, state) do
      {:ok, %{state | log_level: level}}
    end
  end

  # Minimal handler — only tools
  defmodule MinimalHandler do
    @behaviour MCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, [%{"name" => "ping"}], nil, state}
    end

    @impl true
    def handle_call_tool("ping", _args, state) do
      {:ok, [%{"type" => "text", "text" => "pong"}], state}
    end
  end

  # --- Test Helpers ---

  defp start_server(opts \\ []) do
    handler = Keyword.get(opts, :handler, {TestHandler, Keyword.get(opts, :handler_opts, [])})

    server_opts = [
      transport: {MockTransport, []},
      handler: handler,
      server_info: %{name: "test_server", version: "0.1.0"}
    ]

    server_opts =
      if instructions = Keyword.get(opts, :instructions) do
        Keyword.put(server_opts, :instructions, instructions)
      else
        server_opts
      end

    {:ok, server} = MCP.Server.start_link(server_opts)
    transport = MCP.Server.transport(server)
    {server, transport}
  end

  defp do_initialize(server, transport, opts \\ []) do
    init_request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => Keyword.get(opts, :protocol_version, "2025-11-25"),
        "capabilities" => Keyword.get(opts, :capabilities, %{}),
        "clientInfo" => %{"name" => "test_client", "version" => "1.0.0"}
      }
    }

    MockTransport.inject(transport, init_request)
    wait_for_sent(transport, 1)

    # Send initialized notification
    initialized = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    }

    MockTransport.inject(transport, initialized)
    # Give GenServer time to process the notification
    Process.sleep(10)

    assert MCP.Server.status(server) == :ready
  end

  defp inject_request(transport, id, method, params \\ %{}) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    MockTransport.inject(transport, request)
  end

  defp wait_for_sent(transport, expected_count, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_sent(transport, expected_count, deadline)
  end

  defp do_wait_for_sent(transport, expected_count, deadline) do
    messages = MockTransport.sent_messages(transport)

    if length(messages) >= expected_count do
      messages
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Timed out waiting for #{expected_count} sent messages, got #{length(messages)}")
      else
        Process.sleep(5)
        do_wait_for_sent(transport, expected_count, deadline)
      end
    end
  end

  # --- Tests ---

  describe "start_link/1" do
    test "starts server in :waiting status" do
      {server, _transport} = start_server()
      assert MCP.Server.status(server) == :waiting
    end

    test "uses handler module and opts" do
      tools = [%{"name" => "test_tool"}]
      {server, transport} = start_server(handler_opts: [tools: tools])

      do_initialize(server, transport)

      inject_request(transport, 2, "tools/list")
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)
      assert response["result"]["tools"] == tools
    end
  end

  describe "initialization handshake" do
    test "responds to initialize with capabilities and server info" do
      {_server, transport} = start_server()

      init_request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test_client", "version" => "1.0.0"}
        }
      }

      MockTransport.inject(transport, init_request)
      [response] = wait_for_sent(transport, 1)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["protocolVersion"] == "2025-11-25"
      assert response["result"]["serverInfo"]["name"] == "test_server"
      assert response["result"]["serverInfo"]["version"] == "0.1.0"
      assert is_map(response["result"]["capabilities"])
    end

    test "transitions to :ready after initialized notification" do
      {server, transport} = start_server()
      do_initialize(server, transport)
      assert MCP.Server.status(server) == :ready
    end

    test "includes instructions when set" do
      {_server, transport} = start_server(instructions: "Use tools carefully")

      init_request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test_client", "version" => "1.0.0"}
        }
      }

      MockTransport.inject(transport, init_request)
      [response] = wait_for_sent(transport, 1)

      assert response["result"]["instructions"] == "Use tools carefully"
    end

    test "stores client capabilities and info" do
      {server, transport} = start_server()

      init_request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"sampling" => %{}},
          "clientInfo" => %{"name" => "cool_client", "version" => "2.0.0"}
        }
      }

      MockTransport.inject(transport, init_request)
      wait_for_sent(transport, 1)

      # Send initialized notification
      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

      Process.sleep(10)

      client_info = MCP.Server.client_info(server)
      assert client_info.name == "cool_client"
      assert client_info.version == "2.0.0"

      client_caps = MCP.Server.client_capabilities(server)
      assert client_caps.sampling != nil
    end

    test "rejects non-ping requests before initialization" do
      {_server, transport} = start_server()

      inject_request(transport, 1, "tools/list")
      [response] = wait_for_sent(transport, 1)

      assert response["error"]["code"] == -32_600
      assert response["error"]["data"] == "Server not initialized"
    end

    test "rejects duplicate initialization" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1.0"}
      })

      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)
      assert response["error"]["code"] == -32_600
      assert response["error"]["data"] == "Already initialized"
    end
  end

  describe "ping" do
    test "responds to ping before initialization" do
      {_server, transport} = start_server()

      inject_request(transport, 1, "ping")
      [response] = wait_for_sent(transport, 1)

      assert response["id"] == 1
      assert response["result"] == %{}
    end

    test "responds to ping after initialization" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "ping")
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["id"] == 2
      assert response["result"] == %{}
    end
  end

  describe "tools/list" do
    test "returns registered tools" do
      tools = [%{"name" => "echo", "description" => "Echoes input"}]
      {server, transport} = start_server(handler_opts: [tools: tools])
      do_initialize(server, transport)

      inject_request(transport, 2, "tools/list")
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["result"]["tools"] == tools
    end

    test "returns empty list when no tools" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "tools/list")
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["result"]["tools"] == []
    end
  end

  describe "tools/call" do
    test "dispatches to handler and returns content" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "tools/call", %{
        "name" => "echo",
        "arguments" => %{"message" => "hello"}
      })

      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["result"]["content"] == [%{"type" => "text", "text" => "hello"}]
    end

    test "returns isError when tool reports error" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "tools/call", %{"name" => "error_tool"})

      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["result"]["isError"] == true

      assert response["result"]["content"] == [
               %{"type" => "text", "text" => "something went wrong"}
             ]
    end

    test "returns protocol error when handler returns error" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "tools/call", %{"name" => "fail_tool"})

      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["error"]["code"] == -32_602
      assert response["error"]["message"] == "Invalid params for fail_tool"
    end

    test "returns error for unknown tool" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "tools/call", %{
        "name" => "nonexistent",
        "arguments" => %{}
      })

      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["error"]["code"] == -32_601
    end
  end

  describe "resources/list" do
    test "returns registered resources" do
      resources = [%{"uri" => "file://test.txt", "name" => "Test"}]
      {server, transport} = start_server(handler_opts: [resources: resources])
      do_initialize(server, transport)

      inject_request(transport, 2, "resources/list")
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["result"]["resources"] == resources
    end
  end

  describe "resources/read" do
    test "returns resource contents" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "resources/read", %{"uri" => "file://test.txt"})
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["result"]["contents"] == [
               %{"uri" => "file://test.txt", "text" => "Hello, world!"}
             ]
    end

    test "returns error for unknown resource" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "resources/read", %{"uri" => "file://unknown.txt"})
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["error"]["code"] == -32_002
    end
  end

  describe "resources/subscribe and unsubscribe" do
    test "subscribe succeeds" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "resources/subscribe", %{"uri" => "file://test.txt"})
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["result"] == %{}
    end

    test "unsubscribe succeeds" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "resources/subscribe", %{"uri" => "file://test.txt"})
      wait_for_sent(transport, 2)

      inject_request(transport, 3, "resources/unsubscribe", %{"uri" => "file://test.txt"})
      messages = wait_for_sent(transport, 3)
      response = Enum.at(messages, 2)

      assert response["result"] == %{}
    end
  end

  describe "resources/templates/list" do
    test "returns resource templates" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "resources/templates/list")
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["result"]["resourceTemplates"] == [
               %{"uriTemplate" => "file:///{path}", "name" => "File"}
             ]
    end
  end

  describe "prompts/list" do
    test "returns registered prompts" do
      prompts = [%{"name" => "greeting", "description" => "A greeting prompt"}]
      {server, transport} = start_server(handler_opts: [prompts: prompts])
      do_initialize(server, transport)

      inject_request(transport, 2, "prompts/list")
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["result"]["prompts"] == prompts
    end
  end

  describe "prompts/get" do
    test "returns prompt messages" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "prompts/get", %{"name" => "greeting"})
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["result"]["messages"] == [
               %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello!"}}
             ]
    end

    test "returns error for unknown prompt" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "prompts/get", %{"name" => "nonexistent"})
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["error"]["code"] == -32_601
    end
  end

  describe "completion/complete" do
    test "returns completions" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "greeting"},
        "argument" => %{"name" => "lang", "value" => "el"}
      })

      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["result"]["completion"]["values"] == ["elixir", "elm"]
    end
  end

  describe "logging/setLevel" do
    test "sets log level" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "logging/setLevel", %{"level" => "warning"})
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["result"] == %{}
    end
  end

  describe "unknown method" do
    test "returns method not found error" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      inject_request(transport, 2, "unknown/method")
      messages = wait_for_sent(transport, 2)
      response = Enum.at(messages, 1)

      assert response["error"]["code"] == -32_601
      assert response["error"]["data"] == "unknown/method"
    end
  end

  describe "capability detection" do
    test "full handler advertises all capabilities" do
      {_server, transport} = start_server()

      init_request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      MockTransport.inject(transport, init_request)
      [response] = wait_for_sent(transport, 1)

      caps = response["result"]["capabilities"]
      assert caps["tools"] != nil
      assert caps["resources"] != nil
      assert caps["resources"]["subscribe"] == true
      assert caps["prompts"] != nil
      assert caps["logging"] != nil
      assert caps["completions"] != nil
    end

    test "minimal handler only advertises tools" do
      {_server, transport} = start_server(handler: {MinimalHandler, []})

      init_request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      MockTransport.inject(transport, init_request)
      [response] = wait_for_sent(transport, 1)

      caps = response["result"]["capabilities"]
      assert caps["tools"] != nil
      assert caps["resources"] == nil
      assert caps["prompts"] == nil
      assert caps["logging"] == nil
      assert caps["completions"] == nil
    end
  end

  describe "notifications" do
    test "sends tools list changed notification" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      MCP.Server.notify_tools_changed(server)
      messages = wait_for_sent(transport, 2)
      notification = Enum.at(messages, 1)

      assert notification["method"] == "notifications/tools/list_changed"
      refute Map.has_key?(notification, "id")
    end

    test "sends resources list changed notification" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      MCP.Server.notify_resources_changed(server)
      messages = wait_for_sent(transport, 2)
      notification = Enum.at(messages, 1)

      assert notification["method"] == "notifications/resources/list_changed"
    end

    test "sends resource updated notification with URI" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      MCP.Server.notify_resource_updated(server, "file://test.txt")
      messages = wait_for_sent(transport, 2)
      notification = Enum.at(messages, 1)

      assert notification["method"] == "notifications/resources/updated"
      assert notification["params"]["uri"] == "file://test.txt"
    end

    test "sends prompts list changed notification" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      MCP.Server.notify_prompts_changed(server)
      messages = wait_for_sent(transport, 2)
      notification = Enum.at(messages, 1)

      assert notification["method"] == "notifications/prompts/list_changed"
    end

    test "does not send notification before initialization" do
      {server, transport} = start_server()

      MCP.Server.notify_tools_changed(server)
      Process.sleep(20)

      assert MockTransport.sent_messages(transport) == []
    end

    test "sends progress notification" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      MCP.Server.send_progress(server, "token-123", 50, 100)
      messages = wait_for_sent(transport, 2)
      notification = Enum.at(messages, 1)

      assert notification["method"] == "notifications/progress"
      assert notification["params"]["progressToken"] == "token-123"
      assert notification["params"]["progress"] == 50
      assert notification["params"]["total"] == 100
    end
  end

  describe "log messages" do
    test "sends log notification when level is at or above threshold" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      # Set log level first
      inject_request(transport, 2, "logging/setLevel", %{"level" => "warning"})
      wait_for_sent(transport, 2)

      MCP.Server.log(server, "error", "Something broke", "my_module")
      messages = wait_for_sent(transport, 3)
      notification = Enum.at(messages, 2)

      assert notification["method"] == "notifications/message"
      assert notification["params"]["level"] == "error"
      assert notification["params"]["data"] == "Something broke"
      assert notification["params"]["logger"] == "my_module"
    end

    test "does not send log when level is below threshold" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      # Set log level to error
      inject_request(transport, 2, "logging/setLevel", %{"level" => "error"})
      wait_for_sent(transport, 2)

      MCP.Server.log(server, "info", "Just info")
      Process.sleep(20)

      # Should still only have 2 messages (init response + setLevel response)
      assert length(MockTransport.sent_messages(transport)) == 2
    end

    test "does not send log when no level set" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      MCP.Server.log(server, "error", "Something broke")
      Process.sleep(20)

      # Only the init response
      assert length(MockTransport.sent_messages(transport)) == 1
    end
  end

  describe "server-initiated requests" do
    test "sends sampling request to client and receives response" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      # Start async request to client
      task =
        Task.async(fn ->
          MCP.Server.request_sampling(server, %{
            "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "Hi"}}],
            "maxTokens" => 100
          })
        end)

      # Wait for the request to be sent
      messages = wait_for_sent(transport, 2)
      request = Enum.at(messages, 1)

      assert request["method"] == "sampling/createMessage"
      assert request["params"]["maxTokens"] == 100
      request_id = request["id"]

      # Inject response from client
      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "result" => %{
          "role" => "assistant",
          "content" => %{"type" => "text", "text" => "Hello!"},
          "model" => "test-model"
        }
      })

      {:ok, result} = Task.await(task)
      assert result["role"] == "assistant"
      assert result["model"] == "test-model"
    end

    test "sends roots/list request to client" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      task = Task.async(fn -> MCP.Server.request_roots(server) end)

      messages = wait_for_sent(transport, 2)
      request = Enum.at(messages, 1)

      assert request["method"] == "roots/list"
      request_id = request["id"]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "result" => %{
          "roots" => [%{"uri" => "file:///home", "name" => "Home"}]
        }
      })

      {:ok, result} = Task.await(task)
      assert result["roots"] == [%{"uri" => "file:///home", "name" => "Home"}]
    end

    test "sends elicitation request to client" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      task =
        Task.async(fn ->
          MCP.Server.request_elicitation(server, %{
            "message" => "Please confirm",
            "requestedSchema" => %{"type" => "object"}
          })
        end)

      messages = wait_for_sent(transport, 2)
      request = Enum.at(messages, 1)

      assert request["method"] == "elicitation/create"
      request_id = request["id"]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "result" => %{"action" => "accept", "content" => %{"confirmed" => true}}
      })

      {:ok, result} = Task.await(task)
      assert result["action"] == "accept"
    end

    test "returns error when not ready" do
      {server, _transport} = start_server()

      assert {:error, {:not_ready, :waiting}} = MCP.Server.request_roots(server)
    end

    test "handles error response from client" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      task = Task.async(fn -> MCP.Server.request_roots(server) end)

      messages = wait_for_sent(transport, 2)
      request = Enum.at(messages, 1)
      request_id = request["id"]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "error" => %{"code" => -32_601, "message" => "Method not found"}
      })

      {:error, error} = Task.await(task)
      assert error.code == -32_601
    end
  end

  describe "transport closed" do
    test "transitions to :closed status" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      MockTransport.close(transport)
      Process.sleep(10)

      assert MCP.Server.status(server) == :closed
    end

    test "replies to pending server-initiated requests with error" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      task = Task.async(fn -> MCP.Server.request_roots(server) end)
      wait_for_sent(transport, 2)

      MockTransport.close(transport)

      assert {:error, {:transport_closed, :normal}} = Task.await(task)
    end
  end

  describe "close/1" do
    test "closes transport and returns :ok" do
      {server, transport} = start_server()
      do_initialize(server, transport)

      assert :ok = MCP.Server.close(server)
    end
  end
end
