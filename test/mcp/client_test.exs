defmodule MCP.ClientTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Protocol.Error
  alias MCP.Test.MockTransport

  @server_info %{
    "name" => "test-server",
    "version" => "1.0.0"
  }

  @server_capabilities %{
    "tools" => %{"listChanged" => true},
    "resources" => %{"subscribe" => true, "listChanged" => true},
    "prompts" => %{"listChanged" => true}
  }

  # Polls until at least `count` messages have been sent, returns all messages.
  defp wait_for_sent(transport, count, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_sent(transport, count, deadline)
  end

  defp do_wait_for_sent(transport, count, deadline) do
    messages = MockTransport.sent_messages(transport)

    if length(messages) >= count do
      messages
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Timed out waiting for #{count} messages, got #{length(messages)}")
      end

      Process.sleep(5)
      do_wait_for_sent(transport, count, deadline)
    end
  end

  defp start_client(opts \\ []) do
    {:ok, client} =
      Client.start_link(
        Keyword.merge(
          [
            transport: {MockTransport, []},
            client_info: %{name: "test-client", version: "0.1.0"}
          ],
          opts
        )
      )

    transport = Client.transport(client)
    {client, transport}
  end

  # Performs the full connect handshake. After this, the transport has sent
  # 2 messages: the initialize request and the initialized notification.
  defp do_connect(client, transport) do
    task = Task.async(fn -> Client.connect(client) end)

    [init_request] = wait_for_sent(transport, 1)

    assert init_request["method"] == "initialize"
    assert init_request["jsonrpc"] == "2.0"
    assert is_integer(init_request["id"])

    MockTransport.inject(transport, %{
      "jsonrpc" => "2.0",
      "id" => init_request["id"],
      "result" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => @server_capabilities,
        "serverInfo" => @server_info
      }
    })

    {:ok, result} = Task.await(task)

    assert result.server_info.name == "test-server"
    assert result.server_info.version == "1.0.0"
    assert result.protocol_version == "2025-11-25"

    # Wait for initialized notification to be sent (total: 2 messages)
    wait_for_sent(transport, 2)

    :ok
  end

  describe "start_link/1" do
    test "starts client with transport" do
      {client, transport} = start_client()

      assert is_pid(client)
      assert is_pid(transport)
      assert Client.status(client) == :disconnected
      assert Process.alive?(client)
    end

    test "starts client with custom client info" do
      {client, _transport} =
        start_client(client_info: %{name: "custom-app", version: "2.0.0"})

      assert Client.status(client) == :disconnected
      assert Process.alive?(client)
    end
  end

  describe "connect/1" do
    test "performs initialization handshake" do
      {client, transport} = start_client()

      task = Task.async(fn -> Client.connect(client) end)

      [init_request] = wait_for_sent(transport, 1)

      assert init_request["method"] == "initialize"
      assert init_request["params"]["protocolVersion"] == "2025-11-25"
      assert init_request["params"]["clientInfo"]["name"] == "test-client"
      assert init_request["params"]["clientInfo"]["version"] == "0.1.0"
      assert is_map(init_request["params"]["capabilities"])

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => init_request["id"],
        "result" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => @server_capabilities,
          "serverInfo" => @server_info
        }
      })

      {:ok, result} = Task.await(task)

      assert result.server_info.name == "test-server"
      assert result.server_capabilities.tools != nil
      assert result.protocol_version == "2025-11-25"
      assert Client.status(client) == :ready
    end

    test "sends initialized notification after successful handshake" do
      {client, transport} = start_client()

      task = Task.async(fn -> Client.connect(client) end)

      [init_request] = wait_for_sent(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => init_request["id"],
        "result" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => @server_capabilities,
          "serverInfo" => @server_info
        }
      })

      {:ok, _} = Task.await(task)

      # Wait for initialized notification (2 messages total)
      messages = wait_for_sent(transport, 2)

      initialized = Enum.at(messages, 1)
      assert initialized["method"] == "notifications/initialized"
      refute Map.has_key?(initialized, "id")
    end

    test "returns error on initialize failure" do
      {client, transport} = start_client()

      task = Task.async(fn -> Client.connect(client) end)

      [init_request] = wait_for_sent(transport, 1)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => init_request["id"],
        "error" => %{
          "code" => -32_603,
          "message" => "Internal error"
        }
      })

      {:error, error} = Task.await(task)
      assert error.code == -32_603
      assert Client.status(client) == :disconnected
    end

    test "returns already connected when called twice" do
      {client, transport} = start_client()
      do_connect(client, transport)

      {:ok, result} = Client.connect(client)
      assert result.server_info.name == "test-server"
    end

    test "returns error when already initializing" do
      {client, _transport} = start_client()

      _task = Task.async(fn -> Client.connect(client) end)
      # Give the first connect time to start
      Process.sleep(20)

      assert {:error, :already_initializing} = Client.connect(client)
    end
  end

  describe "list_tools/2" do
    test "lists tools from server" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_tools(client) end)

      # Wait for 3 messages: init request + initialized notif + tools/list
      messages = wait_for_sent(transport, 3)
      tools_request = List.last(messages)

      assert tools_request["method"] == "tools/list"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => tools_request["id"],
        "result" => %{
          "tools" => [
            %{
              "name" => "echo",
              "description" => "Echoes input",
              "inputSchema" => %{"type" => "object"}
            }
          ]
        }
      })

      {:ok, result} = Task.await(task)
      assert is_map(result)
      assert length(result["tools"]) == 1
      assert hd(result["tools"])["name"] == "echo"
    end

    test "passes cursor for pagination" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_tools(client, cursor: "page2") end)

      messages = wait_for_sent(transport, 3)
      tools_request = List.last(messages)

      assert tools_request["params"]["cursor"] == "page2"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => tools_request["id"],
        "result" => %{"tools" => []}
      })

      {:ok, _} = Task.await(task)
    end

    test "returns error when not connected" do
      {client, _transport} = start_client()
      assert {:error, :not_ready} = Client.list_tools(client)
    end
  end

  describe "call_tool/4" do
    test "calls a tool on the server" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task =
        Task.async(fn ->
          Client.call_tool(client, "echo", %{"message" => "hello"})
        end)

      messages = wait_for_sent(transport, 3)
      call_request = List.last(messages)

      assert call_request["method"] == "tools/call"
      assert call_request["params"]["name"] == "echo"
      assert call_request["params"]["arguments"] == %{"message" => "hello"}

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => call_request["id"],
        "result" => %{
          "content" => [%{"type" => "text", "text" => "hello"}]
        }
      })

      {:ok, result} = Task.await(task)
      assert hd(result["content"])["text"] == "hello"
    end

    test "handles tool error response" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.call_tool(client, "bad_tool", %{}) end)

      messages = wait_for_sent(transport, 3)
      call_request = List.last(messages)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => call_request["id"],
        "error" => %{
          "code" => -32_601,
          "message" => "Method not found"
        }
      })

      {:error, error} = Task.await(task)
      assert error.code == -32_601
    end
  end

  describe "list_resources/2" do
    test "lists resources from server" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_resources(client) end)

      messages = wait_for_sent(transport, 3)
      request = List.last(messages)

      assert request["method"] == "resources/list"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{
          "resources" => [
            %{"uri" => "file:///test.txt", "name" => "test.txt"}
          ]
        }
      })

      {:ok, result} = Task.await(task)
      assert length(result["resources"]) == 1
    end
  end

  describe "read_resource/3" do
    test "reads a resource by URI" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.read_resource(client, "file:///test.txt") end)

      messages = wait_for_sent(transport, 3)
      request = List.last(messages)

      assert request["method"] == "resources/read"
      assert request["params"]["uri"] == "file:///test.txt"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{
          "contents" => [
            %{"uri" => "file:///test.txt", "text" => "hello world"}
          ]
        }
      })

      {:ok, result} = Task.await(task)
      assert hd(result["contents"])["text"] == "hello world"
    end
  end

  describe "list_resource_templates/2" do
    test "lists resource templates" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_resource_templates(client) end)

      messages = wait_for_sent(transport, 3)
      request = List.last(messages)

      assert request["method"] == "resources/templates/list"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{
          "resourceTemplates" => [
            %{"uriTemplate" => "file:///{path}", "name" => "File"}
          ]
        }
      })

      {:ok, result} = Task.await(task)
      assert length(result["resourceTemplates"]) == 1
    end
  end

  describe "subscribe_resource/3 and unsubscribe_resource/3" do
    test "subscribes and unsubscribes to resource" do
      {client, transport} = start_client()
      do_connect(client, transport)

      # Subscribe
      task = Task.async(fn -> Client.subscribe_resource(client, "file:///test.txt") end)

      messages = wait_for_sent(transport, 3)
      request = List.last(messages)
      assert request["method"] == "resources/subscribe"
      assert request["params"]["uri"] == "file:///test.txt"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{}
      })

      {:ok, _} = Task.await(task)

      # Unsubscribe
      task = Task.async(fn -> Client.unsubscribe_resource(client, "file:///test.txt") end)

      messages = wait_for_sent(transport, 4)
      request = List.last(messages)
      assert request["method"] == "resources/unsubscribe"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{}
      })

      {:ok, _} = Task.await(task)
    end
  end

  describe "list_prompts/2" do
    test "lists prompts from server" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_prompts(client) end)

      messages = wait_for_sent(transport, 3)
      request = List.last(messages)

      assert request["method"] == "prompts/list"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{
          "prompts" => [
            %{"name" => "greeting", "description" => "A greeting prompt"}
          ]
        }
      })

      {:ok, result} = Task.await(task)
      assert length(result["prompts"]) == 1
    end
  end

  describe "get_prompt/4" do
    test "gets a prompt with arguments" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task =
        Task.async(fn ->
          Client.get_prompt(client, "greeting", %{"name" => "World"})
        end)

      messages = wait_for_sent(transport, 3)
      request = List.last(messages)

      assert request["method"] == "prompts/get"
      assert request["params"]["name"] == "greeting"
      assert request["params"]["arguments"] == %{"name" => "World"}

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{
          "description" => "A greeting",
          "messages" => [
            %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello World"}}
          ]
        }
      })

      {:ok, result} = Task.await(task)
      assert result["description"] == "A greeting"
      assert length(result["messages"]) == 1
    end
  end

  describe "ping/2" do
    test "pings the server" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.ping(client) end)

      messages = wait_for_sent(transport, 3)
      request = List.last(messages)

      assert request["method"] == "ping"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{}
      })

      {:ok, _} = Task.await(task)
    end

    test "ping works before initialization" do
      {client, transport} = start_client()
      assert Client.status(client) == :disconnected

      task = Task.async(fn -> Client.ping(client) end)

      [request] = wait_for_sent(transport, 1)
      assert request["method"] == "ping"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{}
      })

      {:ok, _} = Task.await(task)
    end
  end

  describe "close/1" do
    test "closes the client and transport" do
      {client, transport} = start_client()
      do_connect(client, transport)

      assert :ok = Client.close(client)
      assert MockTransport.closed?(transport)
    end

    test "close is idempotent" do
      {client, _transport} = start_client()
      assert :ok = Client.close(client)
      assert :ok = Client.close(client)
    end
  end

  describe "request timeout" do
    test "times out pending request" do
      {client, transport} = start_client(request_timeout: 50)
      do_connect(client, transport)

      # Send a request but don't respond — should time out
      assert {:error, :timeout} = Client.list_tools(client, timeout: 200)
    end
  end

  describe "transport closed" do
    test "notifies pending requests when transport closes" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_tools(client) end)

      # Wait for the request to be sent
      wait_for_sent(transport, 3)

      # Simulate transport closing
      send(client, {:mcp_transport_closed, :normal})

      {:error, {:transport_closed, :normal}} = Task.await(task)
      assert Client.status(client) == :closed
    end
  end

  describe "notification handling" do
    test "dispatches notifications to pid handler" do
      handler = self()
      {client, transport} = start_client(notification_handler: handler)
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/tools/list_changed"
      })

      assert_receive {:mcp_notification, "notifications/tools/list_changed", nil}, 1000
    end

    test "dispatches notifications to function handler" do
      test_pid = self()

      handler = fn method, params ->
        send(test_pid, {:notification, method, params})
      end

      {client, transport} = start_client(notification_handler: handler)
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/resources/updated",
        "params" => %{"uri" => "file:///test.txt"}
      })

      assert_receive {:notification, "notifications/resources/updated",
                      %{"uri" => "file:///test.txt"}},
                     1000
    end

    test "handles log message notifications" do
      handler = self()
      {client, transport} = start_client(notification_handler: handler)
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/message",
        "params" => %{
          "level" => "info",
          "logger" => "test",
          "data" => "hello"
        }
      })

      assert_receive {:mcp_notification, "notifications/message", %{"level" => "info"}}, 1000
    end
  end

  describe "server-initiated requests" do
    test "dispatches sampling request to handler" do
      test_pid = self()

      handler = fn _method, params ->
        send(test_pid, {:sampling_called, params})

        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "response"},
           "model" => "test-model",
           "stopReason" => "endTurn"
         }}
      end

      {client, transport} =
        start_client(
          request_handlers: %{
            "sampling/createMessage" => handler
          }
        )

      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => 100,
        "method" => "sampling/createMessage",
        "params" => %{
          "messages" => [
            %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}
          ],
          "maxTokens" => 100
        }
      })

      assert_receive {:sampling_called, _params}, 1000

      # Wait for response to be sent (init + initialized + sampling response = 3)
      messages = wait_for_sent(transport, 3)
      response = List.last(messages)
      assert response["id"] == 100
      assert response["result"]["role"] == "assistant"
    end

    test "responds with method not found for unknown server requests" do
      {client, transport} = start_client()
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => 200,
        "method" => "unknown/method",
        "params" => %{}
      })

      # Wait for error response to be sent (init + initialized + error response = 3)
      messages = wait_for_sent(transport, 3)
      response = List.last(messages)
      assert response["id"] == 200
      assert response["error"]["code"] == Error.method_not_found_code()
    end
  end

  describe "pagination helpers" do
    test "list_all_tools paginates through multiple pages" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task = Task.async(fn -> Client.list_all_tools(client) end)

      # First page: init + initialized + tools/list = 3
      messages = wait_for_sent(transport, 3)
      request = List.last(messages)
      assert request["method"] == "tools/list"
      refute request["params"]["cursor"]

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{
          "tools" => [%{"name" => "tool1", "inputSchema" => %{"type" => "object"}}],
          "nextCursor" => "cursor1"
        }
      })

      # Second page: + 1 more = 4
      messages = wait_for_sent(transport, 4)
      request = List.last(messages)
      assert request["params"]["cursor"] == "cursor1"

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{
          "tools" => [%{"name" => "tool2", "inputSchema" => %{"type" => "object"}}]
        }
      })

      {:ok, tools} = Task.await(task)
      assert length(tools) == 2
    end
  end

  describe "server_capabilities/1 and server_info/1" do
    test "returns server capabilities after connect" do
      {client, transport} = start_client()
      do_connect(client, transport)

      caps = Client.server_capabilities(client)
      assert caps.tools != nil
      assert caps.resources != nil
      assert caps.prompts != nil
    end

    test "returns server info after connect" do
      {client, transport} = start_client()
      do_connect(client, transport)

      info = Client.server_info(client)
      assert info.name == "test-server"
      assert info.version == "1.0.0"
    end
  end

  describe "concurrent requests" do
    test "handles multiple concurrent requests" do
      {client, transport} = start_client()
      do_connect(client, transport)

      task1 = Task.async(fn -> Client.list_tools(client) end)
      task2 = Task.async(fn -> Client.list_resources(client) end)

      # Wait for both requests: init + initialized + 2 requests = 4
      messages = wait_for_sent(transport, 4)

      # Get the two list requests (skip init request and initialized notification)
      list_requests =
        messages
        |> Enum.filter(&(Map.has_key?(&1, "id") && &1["method"] != "initialize"))

      Enum.each(list_requests, fn req ->
        result =
          case req["method"] do
            "tools/list" -> %{"tools" => []}
            "resources/list" -> %{"resources" => []}
          end

        MockTransport.inject(transport, %{
          "jsonrpc" => "2.0",
          "id" => req["id"],
          "result" => result
        })
      end)

      {:ok, _} = Task.await(task1)
      {:ok, _} = Task.await(task2)
    end
  end

  describe "sampling callback (on_sampling)" do
    test "auto-advertises sampling capability when on_sampling provided" do
      test_pid = self()

      callback = fn _params ->
        send(test_pid, :sampling_called)

        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "hi"},
           "model" => "test",
           "stopReason" => "endTurn"
         }}
      end

      {client, transport} = start_client(on_sampling: callback)

      task = Task.async(fn -> Client.connect(client) end)

      [init_request] = wait_for_sent(transport, 1)

      # Verify sampling capability is advertised
      assert init_request["params"]["capabilities"]["sampling"] == %{}

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => init_request["id"],
        "result" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => @server_capabilities,
          "serverInfo" => @server_info
        }
      })

      {:ok, _} = Task.await(task)
    end

    test "dispatches sampling/createMessage to on_sampling callback" do
      test_pid = self()

      callback = fn params ->
        send(test_pid, {:sampling_called, params})

        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "response"},
           "model" => "test-model",
           "stopReason" => "endTurn"
         }}
      end

      {client, transport} = start_client(on_sampling: callback)
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => 100,
        "method" => "sampling/createMessage",
        "params" => %{
          "messages" => [
            %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}
          ],
          "maxTokens" => 100
        }
      })

      assert_receive {:sampling_called, params}, 1000
      assert params["maxTokens"] == 100

      messages = wait_for_sent(transport, 3)
      response = List.last(messages)
      assert response["id"] == 100
      assert response["result"]["role"] == "assistant"
      assert response["result"]["model"] == "test-model"
    end

    test "returns error when sampling callback returns error" do
      callback = fn _params ->
        {:error, %Error{code: -1, message: "User rejected sampling"}}
      end

      {client, transport} = start_client(on_sampling: callback)
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => 101,
        "method" => "sampling/createMessage",
        "params" => %{"messages" => [], "maxTokens" => 10}
      })

      messages = wait_for_sent(transport, 3)
      response = List.last(messages)
      assert response["id"] == 101
      assert response["error"]["code"] == -1
      assert response["error"]["message"] == "User rejected sampling"
    end

    test "returns method not found when no sampling handler registered" do
      {client, transport} = start_client()
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => 102,
        "method" => "sampling/createMessage",
        "params" => %{"messages" => [], "maxTokens" => 10}
      })

      messages = wait_for_sent(transport, 3)
      response = List.last(messages)
      assert response["id"] == 102
      assert response["error"]["code"] == Error.method_not_found_code()
    end
  end

  describe "roots callback (on_roots_list)" do
    test "auto-advertises roots capability when on_roots_list provided" do
      callback = fn _params ->
        {:ok, %{"roots" => [%{"uri" => "file:///project", "name" => "project"}]}}
      end

      {client, transport} = start_client(on_roots_list: callback)

      task = Task.async(fn -> Client.connect(client) end)

      [init_request] = wait_for_sent(transport, 1)

      # Verify roots capability is advertised with listChanged
      assert init_request["params"]["capabilities"]["roots"]["listChanged"] == true

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => init_request["id"],
        "result" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => @server_capabilities,
          "serverInfo" => @server_info
        }
      })

      {:ok, _} = Task.await(task)
    end

    test "dispatches roots/list to on_roots_list callback" do
      test_pid = self()

      callback = fn params ->
        send(test_pid, {:roots_called, params})
        {:ok, %{"roots" => [%{"uri" => "file:///project", "name" => "project"}]}}
      end

      {client, transport} = start_client(on_roots_list: callback)
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => 200,
        "method" => "roots/list",
        "params" => %{}
      })

      assert_receive {:roots_called, _params}, 1000

      messages = wait_for_sent(transport, 3)
      response = List.last(messages)
      assert response["id"] == 200
      assert length(response["result"]["roots"]) == 1
      assert hd(response["result"]["roots"])["uri"] == "file:///project"
    end

    test "notify_roots_changed sends notification to server" do
      callback = fn _params ->
        {:ok, %{"roots" => []}}
      end

      {client, transport} = start_client(on_roots_list: callback)
      do_connect(client, transport)

      Client.notify_roots_changed(client)

      messages = wait_for_sent(transport, 3)
      notification = List.last(messages)
      assert notification["method"] == "notifications/roots/list_changed"
      refute Map.has_key?(notification, "id")
    end

    test "notify_roots_changed is silently dropped when not ready" do
      {client, _transport} = start_client()

      # Should not crash, just silently dropped
      Client.notify_roots_changed(client)
      assert Client.status(client) == :disconnected
    end
  end

  describe "elicitation callback (on_elicitation)" do
    test "auto-advertises elicitation capability when on_elicitation provided" do
      callback = fn _params ->
        {:ok, %{"action" => "accept", "content" => %{"name" => "Claude"}}}
      end

      {client, transport} = start_client(on_elicitation: callback)

      task = Task.async(fn -> Client.connect(client) end)

      [init_request] = wait_for_sent(transport, 1)

      # Verify elicitation capability is advertised
      caps = init_request["params"]["capabilities"]["elicitation"]
      assert is_map(caps)
      assert Map.has_key?(caps, "form")
      assert Map.has_key?(caps, "url")

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => init_request["id"],
        "result" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => @server_capabilities,
          "serverInfo" => @server_info
        }
      })

      {:ok, _} = Task.await(task)
    end

    test "dispatches elicitation/create to on_elicitation callback" do
      test_pid = self()

      callback = fn params ->
        send(test_pid, {:elicitation_called, params})
        {:ok, %{"action" => "accept", "content" => %{"name" => "World"}}}
      end

      {client, transport} = start_client(on_elicitation: callback)
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => 300,
        "method" => "elicitation/create",
        "params" => %{
          "message" => "What is your name?",
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}}
          }
        }
      })

      assert_receive {:elicitation_called, params}, 1000
      assert params["message"] == "What is your name?"

      messages = wait_for_sent(transport, 3)
      response = List.last(messages)
      assert response["id"] == 300
      assert response["result"]["action"] == "accept"
      assert response["result"]["content"]["name"] == "World"
    end

    test "handles elicitation decline" do
      callback = fn _params ->
        {:ok, %{"action" => "decline"}}
      end

      {client, transport} = start_client(on_elicitation: callback)
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => 301,
        "method" => "elicitation/create",
        "params" => %{"message" => "Enter data"}
      })

      messages = wait_for_sent(transport, 3)
      response = List.last(messages)
      assert response["id"] == 301
      assert response["result"]["action"] == "decline"
    end
  end

  describe "cancel/3" do
    test "sends cancellation notification" do
      {client, transport} = start_client()
      do_connect(client, transport)

      Client.cancel(client, 42, "no longer needed")

      messages = wait_for_sent(transport, 3)
      notification = List.last(messages)
      assert notification["method"] == "notifications/cancelled"
      assert notification["params"]["requestId"] == 42
      assert notification["params"]["reason"] == "no longer needed"
      refute Map.has_key?(notification, "id")
    end

    test "sends cancellation without reason" do
      {client, transport} = start_client()
      do_connect(client, transport)

      Client.cancel(client, 99)

      messages = wait_for_sent(transport, 3)
      notification = List.last(messages)
      assert notification["method"] == "notifications/cancelled"
      assert notification["params"]["requestId"] == 99
      refute Map.has_key?(notification["params"], "reason")
    end

    test "cancel is silently dropped when closed" do
      {client, _transport} = start_client()
      :ok = Client.close(client)

      # Should not crash
      Client.cancel(client, 1)
    end
  end

  describe "progress notifications" do
    test "progress notifications are dispatched to notification handler" do
      handler = self()
      {client, transport} = start_client(notification_handler: handler)
      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{
          "progressToken" => "token-1",
          "progress" => 50,
          "total" => 100,
          "message" => "Processing..."
        }
      })

      assert_receive {:mcp_notification, "notifications/progress", params}, 1000
      assert params["progressToken"] == "token-1"
      assert params["progress"] == 50
      assert params["total"] == 100
    end
  end

  describe "combined capabilities" do
    test "advertises all capabilities when all callbacks provided" do
      {client, transport} =
        start_client(
          on_sampling: fn _params -> {:ok, %{}} end,
          on_roots_list: fn _params -> {:ok, %{"roots" => []}} end,
          on_elicitation: fn _params -> {:ok, %{"action" => "decline"}} end
        )

      task = Task.async(fn -> Client.connect(client) end)

      [init_request] = wait_for_sent(transport, 1)
      caps = init_request["params"]["capabilities"]

      assert caps["sampling"] == %{}
      assert caps["roots"]["listChanged"] == true
      assert is_map(caps["elicitation"])

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => init_request["id"],
        "result" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => @server_capabilities,
          "serverInfo" => @server_info
        }
      })

      {:ok, _} = Task.await(task)
    end

    test "explicit request_handlers override auto-generated ones" do
      test_pid = self()

      explicit_handler = fn _method, _params ->
        send(test_pid, :explicit_handler_called)

        {:ok,
         %{"role" => "assistant", "content" => %{}, "model" => "m", "stopReason" => "endTurn"}}
      end

      {client, transport} =
        start_client(
          on_sampling: fn _params ->
            send(test_pid, :auto_handler_called)
            {:ok, %{}}
          end,
          request_handlers: %{"sampling/createMessage" => explicit_handler}
        )

      do_connect(client, transport)

      MockTransport.inject(transport, %{
        "jsonrpc" => "2.0",
        "id" => 500,
        "method" => "sampling/createMessage",
        "params" => %{"messages" => [], "maxTokens" => 10}
      })

      assert_receive :explicit_handler_called, 1000
      refute_receive :auto_handler_called, 100
    end
  end
end
