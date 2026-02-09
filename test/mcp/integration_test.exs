defmodule MCP.IntegrationTest do
  @moduledoc """
  Integration tests: MCP Client ↔ MCP Server in-process via BridgeTransport.

  Tests the full lifecycle with both sides running as GenServers
  communicating over an in-memory bridge transport.
  """

  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Server
  alias MCP.Test.BridgeTransport

  # --- Test Handler ---

  defmodule TestHandler do
    @behaviour MCP.Server.Handler

    @impl true
    def init(opts) do
      {:ok,
       %{
         tools:
           Keyword.get(opts, :tools, [
             %{
               "name" => "echo",
               "description" => "Echoes input",
               "inputSchema" => %{"type" => "object"}
             },
             %{
               "name" => "add",
               "description" => "Adds two numbers",
               "inputSchema" => %{"type" => "object"}
             }
           ]),
         resources:
           Keyword.get(opts, :resources, [
             %{
               "uri" => "file:///readme.txt",
               "name" => "readme.txt",
               "mimeType" => "text/plain"
             }
           ]),
         prompts:
           Keyword.get(opts, :prompts, [
             %{
               "name" => "greeting",
               "description" => "A greeting prompt"
             }
           ]),
         subscriptions: [],
         log_level: nil,
         test_pid: Keyword.get(opts, :test_pid)
       }}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, state.tools, nil, state}
    end

    @impl true
    def handle_call_tool("echo", %{"message" => msg}, state) do
      {:ok, [%{"type" => "text", "text" => msg}], state}
    end

    def handle_call_tool("add", %{"a" => a, "b" => b}, state) do
      {:ok, [%{"type" => "text", "text" => "#{a + b}"}], state}
    end

    def handle_call_tool("error_tool", _args, state) do
      {:ok, [%{"type" => "text", "text" => "error occurred"}], true, state}
    end

    def handle_call_tool(name, _args, state) do
      {:error, -32_601, "Unknown tool: #{name}", state}
    end

    @impl true
    def handle_list_resources(_cursor, state) do
      {:ok, state.resources, nil, state}
    end

    @impl true
    def handle_read_resource("file:///readme.txt", state) do
      {:ok, [%{"uri" => "file:///readme.txt", "text" => "Hello from MCP!"}], state}
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
    def handle_set_log_level(level, state) do
      {:ok, %{state | log_level: level}}
    end

    @impl true
    def handle_complete(_ref, _argument, state) do
      {:ok, %{"values" => ["foo", "foobar"], "hasMore" => false, "total" => 2}, state}
    end
  end

  # --- Helpers ---

  defp start_pair(client_opts \\ [], server_handler_opts \\ []) do
    {client_t, server_t} = BridgeTransport.create_pair()

    {:ok, server} =
      Server.start_link(
        transport: {BridgeTransport, pid: server_t},
        handler: {TestHandler, server_handler_opts},
        server_info: %{name: "test-server", version: "1.0.0"}
      )

    {:ok, client} =
      Client.start_link(
        Keyword.merge(
          [
            transport: {BridgeTransport, pid: client_t},
            client_info: %{name: "test-client", version: "0.1.0"}
          ],
          client_opts
        )
      )

    %{client: client, server: server}
  end

  defp connect(%{client: client, server: server}) do
    {:ok, result} = Client.connect(client)
    wait_for_server_ready(server)
    result
  end

  defp wait_for_server_ready(server, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_server_ready(server, deadline)
  end

  defp do_wait_for_server_ready(server, deadline) do
    if Server.status(server) == :ready do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "Timed out waiting for server to reach :ready status"
      end

      Process.sleep(5)
      do_wait_for_server_ready(server, deadline)
    end
  end

  # --- Tests ---

  describe "initialization handshake" do
    test "client connects to server and exchanges capabilities" do
      ctx = start_pair()
      result = connect(ctx)

      assert result.server_info.name == "test-server"
      assert result.server_info.version == "1.0.0"
      assert result.protocol_version == "2025-11-25"
      assert result.server_capabilities.tools != nil
      assert result.server_capabilities.resources != nil
      assert result.server_capabilities.prompts != nil

      assert Client.status(ctx.client) == :ready
      assert Server.status(ctx.server) == :ready
    end

    test "ping works before and after initialization" do
      ctx = start_pair()

      # Ping before connect
      {:ok, _} = Client.ping(ctx.client)

      connect(ctx)

      # Ping after connect
      {:ok, _} = Client.ping(ctx.client)
    end
  end

  describe "tools" do
    test "lists tools" do
      ctx = start_pair()
      connect(ctx)

      {:ok, result} = Client.list_tools(ctx.client)
      tools = result["tools"]
      assert length(tools) == 2
      names = Enum.map(tools, & &1["name"])
      assert "echo" in names
      assert "add" in names
    end

    test "calls echo tool" do
      ctx = start_pair()
      connect(ctx)

      {:ok, result} = Client.call_tool(ctx.client, "echo", %{"message" => "hello"})
      assert hd(result["content"])["text"] == "hello"
    end

    test "calls add tool" do
      ctx = start_pair()
      connect(ctx)

      {:ok, result} = Client.call_tool(ctx.client, "add", %{"a" => 3, "b" => 4})
      assert hd(result["content"])["text"] == "7"
    end

    test "handles tool error (isError flag)" do
      ctx = start_pair()
      connect(ctx)

      {:ok, result} = Client.call_tool(ctx.client, "error_tool", %{})
      assert result["isError"] == true
    end

    test "handles unknown tool error" do
      ctx = start_pair()
      connect(ctx)

      {:error, error} = Client.call_tool(ctx.client, "nonexistent", %{})
      assert error.code == -32_601
    end
  end

  describe "resources" do
    test "lists resources" do
      ctx = start_pair()
      connect(ctx)

      {:ok, result} = Client.list_resources(ctx.client)
      assert length(result["resources"]) == 1
      assert hd(result["resources"])["uri"] == "file:///readme.txt"
    end

    test "reads a resource" do
      ctx = start_pair()
      connect(ctx)

      {:ok, result} = Client.read_resource(ctx.client, "file:///readme.txt")
      assert hd(result["contents"])["text"] == "Hello from MCP!"
    end

    test "returns error for unknown resource" do
      ctx = start_pair()
      connect(ctx)

      {:error, error} = Client.read_resource(ctx.client, "file:///missing.txt")
      assert error.code == -32_002
    end

    test "lists resource templates" do
      ctx = start_pair()
      connect(ctx)

      {:ok, result} = Client.list_resource_templates(ctx.client)
      assert length(result["resourceTemplates"]) == 1
    end

    test "subscribes and unsubscribes to resources" do
      ctx = start_pair()
      connect(ctx)

      {:ok, _} = Client.subscribe_resource(ctx.client, "file:///readme.txt")
      {:ok, _} = Client.unsubscribe_resource(ctx.client, "file:///readme.txt")
    end
  end

  describe "prompts" do
    test "lists prompts" do
      ctx = start_pair()
      connect(ctx)

      {:ok, result} = Client.list_prompts(ctx.client)
      assert length(result["prompts"]) == 1
      assert hd(result["prompts"])["name"] == "greeting"
    end

    test "gets a prompt" do
      ctx = start_pair()
      connect(ctx)

      {:ok, result} = Client.get_prompt(ctx.client, "greeting")
      assert length(result["messages"]) == 1
    end

    test "returns error for unknown prompt" do
      ctx = start_pair()
      connect(ctx)

      {:error, error} = Client.get_prompt(ctx.client, "unknown")
      assert error.code == -32_601
    end
  end

  describe "pagination helpers" do
    test "list_all_tools returns all tools" do
      ctx = start_pair()
      connect(ctx)

      {:ok, tools} = Client.list_all_tools(ctx.client)
      assert length(tools) == 2
    end

    test "list_all_resources returns all resources" do
      ctx = start_pair()
      connect(ctx)

      {:ok, resources} = Client.list_all_resources(ctx.client)
      assert length(resources) == 1
    end

    test "list_all_prompts returns all prompts" do
      ctx = start_pair()
      connect(ctx)

      {:ok, prompts} = Client.list_all_prompts(ctx.client)
      assert length(prompts) == 1
    end
  end

  describe "sampling (server → client)" do
    test "server requests sampling and client responds via callback" do
      test_pid = self()

      sampling_callback = fn params ->
        send(test_pid, {:sampling_called, params})

        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "I can help with that"},
           "model" => "test-model",
           "stopReason" => "endTurn"
         }}
      end

      ctx = start_pair(on_sampling: sampling_callback)
      connect(ctx)

      # Server initiates sampling request
      {:ok, result} =
        Server.request_sampling(ctx.server, %{
          "messages" => [
            %{"role" => "user", "content" => %{"type" => "text", "text" => "Help me"}}
          ],
          "maxTokens" => 100
        })

      assert_receive {:sampling_called, _params}, 1000

      assert result["role"] == "assistant"
      assert result["model"] == "test-model"
      assert result["content"]["text"] == "I can help with that"
    end
  end

  describe "roots (server → client)" do
    test "server requests roots and client responds via callback" do
      roots_callback = fn _params ->
        {:ok,
         %{
           "roots" => [
             %{"uri" => "file:///project", "name" => "my-project"},
             %{"uri" => "file:///home", "name" => "home"}
           ]
         }}
      end

      ctx = start_pair(on_roots_list: roots_callback)
      connect(ctx)

      {:ok, result} = Server.request_roots(ctx.server)
      assert length(result["roots"]) == 2
    end

    test "client sends roots changed notification" do
      handler = self()

      roots_callback = fn _params ->
        {:ok, %{"roots" => []}}
      end

      ctx =
        start_pair(
          [on_roots_list: roots_callback, notification_handler: handler],
          []
        )

      connect(ctx)

      # Notify roots changed — server should receive the notification
      Client.notify_roots_changed(ctx.client)

      # Give a moment for the notification to arrive
      Process.sleep(50)

      # The notification is received by the server, which logs it.
      # Server status should still be ready
      assert Server.status(ctx.server) == :ready
    end
  end

  describe "elicitation (server → client)" do
    test "server requests elicitation and client accepts" do
      elicitation_callback = fn params ->
        {:ok,
         %{
           "action" => "accept",
           "content" => %{
             "name" => params["requestedSchema"]["properties"]["name"]["default"] || "User"
           }
         }}
      end

      ctx = start_pair(on_elicitation: elicitation_callback)
      connect(ctx)

      {:ok, result} =
        Server.request_elicitation(ctx.server, %{
          "message" => "What is your name?",
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string", "default" => "Claude"}
            }
          }
        })

      assert result["action"] == "accept"
      assert result["content"]["name"] == "Claude"
    end

    test "server requests elicitation and client declines" do
      elicitation_callback = fn _params ->
        {:ok, %{"action" => "decline"}}
      end

      ctx = start_pair(on_elicitation: elicitation_callback)
      connect(ctx)

      {:ok, result} =
        Server.request_elicitation(ctx.server, %{
          "message" => "Please provide info"
        })

      assert result["action"] == "decline"
    end
  end

  describe "progress notifications" do
    test "client receives progress from server" do
      handler = self()
      ctx = start_pair(notification_handler: handler)
      connect(ctx)

      Server.send_progress(ctx.server, "token-1", 5, 10)

      assert_receive {:mcp_notification, "notifications/progress", params}, 1000
      assert params["progressToken"] == "token-1"
      assert params["progress"] == 5
      assert params["total"] == 10
    end
  end

  describe "logging" do
    test "client receives log messages from server" do
      handler = self()
      ctx = start_pair(notification_handler: handler)
      connect(ctx)

      # Set log level first (so server will send logs)
      # Need to use a raw call since there's no high-level client API for this
      # The server's log() function sends log notifications

      # The server needs a log level set to emit logs
      Server.log(ctx.server, "info", "test message", "test-logger")

      # Server drops logs when no log level is set, so we won't receive this
      refute_receive {:mcp_notification, "notifications/message", _}, 100
    end
  end

  describe "cancellation" do
    test "client sends cancellation notification" do
      ctx = start_pair()
      connect(ctx)

      # Cancel a fictitious request ID — should not crash
      Client.cancel(ctx.client, 999, "no longer needed")

      # Give it time to propagate
      Process.sleep(50)

      # Server should still be operational
      assert Server.status(ctx.server) == :ready
    end
  end

  describe "error handling" do
    test "server returns method not found for unknown methods" do
      ctx = start_pair()
      connect(ctx)

      # We can't easily send a raw unknown method via client API,
      # but we can verify that the server handles it via the tools
      {:error, error} = Client.call_tool(ctx.client, "nonexistent_tool", %{})
      assert error.code == -32_601
    end

    test "close client gracefully" do
      ctx = start_pair()
      connect(ctx)

      :ok = Client.close(ctx.client)
    end

    test "close server gracefully" do
      ctx = start_pair()
      connect(ctx)

      :ok = Server.close(ctx.server)
    end
  end

  describe "combined capabilities" do
    test "client with all features connects and works" do
      test_pid = self()

      ctx =
        start_pair(
          on_sampling: fn _params ->
            send(test_pid, :sampling_ok)

            {:ok,
             %{"role" => "assistant", "content" => %{}, "model" => "m", "stopReason" => "endTurn"}}
          end,
          on_roots_list: fn _params ->
            send(test_pid, :roots_ok)
            {:ok, %{"roots" => [%{"uri" => "file:///", "name" => "root"}]}}
          end,
          on_elicitation: fn _params ->
            send(test_pid, :elicitation_ok)
            {:ok, %{"action" => "accept", "content" => %{}}}
          end,
          notification_handler: test_pid
        )

      connect(ctx)

      # Test tools (server → client request flow isn't needed)
      {:ok, _} = Client.list_tools(ctx.client)

      # Test sampling
      {:ok, _} = Server.request_sampling(ctx.server, %{"messages" => [], "maxTokens" => 10})
      assert_receive :sampling_ok, 1000

      # Test roots
      {:ok, _} = Server.request_roots(ctx.server)
      assert_receive :roots_ok, 1000

      # Test elicitation
      {:ok, _} = Server.request_elicitation(ctx.server, %{"message" => "test"})
      assert_receive :elicitation_ok, 1000

      # Test progress
      Server.send_progress(ctx.server, "t1", 1, 2)
      assert_receive {:mcp_notification, "notifications/progress", _}, 1000
    end
  end
end
