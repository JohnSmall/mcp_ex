defmodule MCP.Client do
  @moduledoc """
  MCP client implementation.

  A GenServer that manages a connection to an MCP server via a pluggable
  transport. Handles the initialization handshake, request/response matching,
  and provides the full MCP client API.

  ## Usage

      {:ok, client} = MCP.Client.start_link(
        transport: {MCP.Transport.Stdio, command: "mcp-server", args: []},
        client_info: %{name: "my_app", version: "1.0.0"}
      )

      {:ok, result} = MCP.Client.connect(client)
      {:ok, tools} = MCP.Client.list_tools(client)
      {:ok, result} = MCP.Client.call_tool(client, "my_tool", %{"arg" => "val"})

  ## Options

    * `:transport` — `{module, opts}` transport spec. The client starts the
      transport in its init, setting itself as the owner.
    * `:client_info` — `%Implementation{}` or map with `:name` and `:version`.
    * `:client_capabilities` — `%ClientCapabilities{}` (default: empty).
    * `:notification_handler` — pid or `(method, params -> any())` for server notifications.
    * `:request_handlers` — `%{method => callback}` for server-initiated requests
      (sampling, roots, elicitation).
    * `:request_timeout` — default timeout in ms for requests (default: 30_000).
  """

  use GenServer

  require Logger

  alias MCP.Protocol
  alias MCP.Protocol.Capabilities.ClientCapabilities
  alias MCP.Protocol.Error
  alias MCP.Protocol.Messages.{Initialize, Notification, Request, Response}
  alias MCP.Protocol.Methods
  alias MCP.Protocol.Types.Implementation

  defstruct [
    :transport_module,
    :transport_pid,
    :server_capabilities,
    :server_info,
    :client_info,
    :client_capabilities,
    :status,
    :notification_handler,
    :request_handlers,
    :pending_requests,
    :next_id,
    :request_timeout,
    :connect_from
  ]

  @default_request_timeout 30_000

  # --- Public API ---

  @doc """
  Starts the client GenServer and its transport.
  """
  def start_link(opts) do
    {gen_opts, client_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, client_opts, gen_opts)
  end

  @doc """
  Performs the MCP initialization handshake.

  Sends `initialize` request to the server and waits for the response.
  On success, sends `initialized` notification and returns server info.

  Returns `{:ok, result}` where result contains `:server_info`,
  `:server_capabilities`, and `:protocol_version`.
  """
  def connect(client, timeout \\ 60_000) do
    GenServer.call(client, :connect, timeout)
  end

  @doc """
  Lists available tools from the server.

  Options:
    * `:cursor` — pagination cursor from a previous response.
    * `:timeout` — request timeout in ms.

  Returns `{:ok, %Tools.ListResult{}}` on success.
  """
  def list_tools(client, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout)
    GenServer.call(client, {:list_tools, opts}, timeout || @default_request_timeout)
  end

  @doc """
  Calls a tool on the server.

  Returns `{:ok, %Tools.CallResult{}}` on success.
  """
  def call_tool(client, name, arguments \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout)
    GenServer.call(client, {:call_tool, name, arguments}, timeout || @default_request_timeout)
  end

  @doc """
  Lists available resources from the server.

  Options:
    * `:cursor` — pagination cursor.
    * `:timeout` — request timeout in ms.

  Returns `{:ok, %Resources.ListResult{}}` on success.
  """
  def list_resources(client, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout)
    GenServer.call(client, {:list_resources, opts}, timeout || @default_request_timeout)
  end

  @doc """
  Reads a resource by URI.

  Returns `{:ok, %Resources.ReadResult{}}` on success.
  """
  def read_resource(client, uri, opts \\ []) do
    timeout = Keyword.get(opts, :timeout)
    GenServer.call(client, {:read_resource, uri}, timeout || @default_request_timeout)
  end

  @doc """
  Lists resource templates from the server.

  Options:
    * `:cursor` — pagination cursor.
    * `:timeout` — request timeout in ms.

  Returns `{:ok, %Resources.ListTemplatesResult{}}` on success.
  """
  def list_resource_templates(client, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout)

    GenServer.call(
      client,
      {:list_resource_templates, opts},
      timeout || @default_request_timeout
    )
  end

  @doc """
  Subscribes to updates for a resource URI.
  """
  def subscribe_resource(client, uri, opts \\ []) do
    timeout = Keyword.get(opts, :timeout)
    GenServer.call(client, {:subscribe_resource, uri}, timeout || @default_request_timeout)
  end

  @doc """
  Unsubscribes from updates for a resource URI.
  """
  def unsubscribe_resource(client, uri, opts \\ []) do
    timeout = Keyword.get(opts, :timeout)
    GenServer.call(client, {:unsubscribe_resource, uri}, timeout || @default_request_timeout)
  end

  @doc """
  Lists available prompts from the server.

  Options:
    * `:cursor` — pagination cursor.
    * `:timeout` — request timeout in ms.

  Returns `{:ok, %Prompts.ListResult{}}` on success.
  """
  def list_prompts(client, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout)
    GenServer.call(client, {:list_prompts, opts}, timeout || @default_request_timeout)
  end

  @doc """
  Gets a specific prompt by name with optional arguments.

  Returns `{:ok, %Prompts.GetResult{}}` on success.
  """
  def get_prompt(client, name, arguments \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout)
    GenServer.call(client, {:get_prompt, name, arguments}, timeout || @default_request_timeout)
  end

  @doc """
  Sends a ping request. Works even before initialization.
  """
  def ping(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout)
    GenServer.call(client, :ping, timeout || @default_request_timeout)
  end

  @doc """
  Closes the client and its transport.
  """
  def close(client) do
    GenServer.call(client, :close)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Returns the transport pid (useful for testing with MockTransport).
  """
  def transport(client) do
    GenServer.call(client, :get_transport)
  end

  @doc """
  Returns the current client status.
  """
  def status(client) do
    GenServer.call(client, :get_status)
  end

  @doc """
  Returns the negotiated server capabilities.
  """
  def server_capabilities(client) do
    GenServer.call(client, :get_server_capabilities)
  end

  @doc """
  Returns the server info from initialization.
  """
  def server_info(client) do
    GenServer.call(client, :get_server_info)
  end

  # --- Pagination helpers ---

  @doc """
  Lists all tools, automatically paginating through all pages.

  Returns `{:ok, [Tool.t()]}` on success.
  """
  def list_all_tools(client, opts \\ []) do
    list_all(client, :list_tools, :tools, opts)
  end

  @doc """
  Lists all resources, automatically paginating through all pages.

  Returns `{:ok, [Resource.t()]}` on success.
  """
  def list_all_resources(client, opts \\ []) do
    list_all(client, :list_resources, :resources, opts)
  end

  @doc """
  Lists all resource templates, automatically paginating through all pages.

  Returns `{:ok, [ResourceTemplate.t()]}` on success.
  """
  def list_all_resource_templates(client, opts \\ []) do
    list_all(client, :list_resource_templates, :resource_templates, opts)
  end

  @doc """
  Lists all prompts, automatically paginating through all pages.

  Returns `{:ok, [Prompt.t()]}` on success.
  """
  def list_all_prompts(client, opts \\ []) do
    list_all(client, :list_prompts, :prompts, opts)
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    {transport_spec, opts} = Keyword.pop!(opts, :transport)
    client_info = build_client_info(Keyword.get(opts, :client_info, %{name: "mcp_ex", version: "0.1.0"}))
    client_capabilities = Keyword.get(opts, :client_capabilities, %ClientCapabilities{})
    notification_handler = Keyword.get(opts, :notification_handler)
    request_handlers = Keyword.get(opts, :request_handlers, %{})
    request_timeout = Keyword.get(opts, :request_timeout, @default_request_timeout)

    case start_transport(transport_spec) do
      {:ok, module, pid} ->
        state = %__MODULE__{
          transport_module: module,
          transport_pid: pid,
          client_info: client_info,
          client_capabilities: client_capabilities,
          status: :disconnected,
          notification_handler: notification_handler,
          request_handlers: request_handlers,
          pending_requests: %{},
          next_id: 1,
          request_timeout: request_timeout
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:connect, from, %{status: :disconnected} = state) do
    params = Initialize.Params.to_map(%Initialize.Params{
      protocol_version: Protocol.protocol_version(),
      capabilities: state.client_capabilities,
      client_info: state.client_info
    })

    {id, state} = next_id(state)
    send_request(state, id, Methods.initialize(), params)

    timeout_ref = schedule_timeout(id, state.request_timeout)

    state = %{state |
      status: :initializing,
      connect_from: from,
      pending_requests: Map.put(state.pending_requests, id, {from, timeout_ref})
    }

    {:noreply, state}
  end

  def handle_call(:connect, _from, %{status: :ready} = state) do
    {:reply, {:ok, init_result(state)}, state}
  end

  def handle_call(:connect, _from, %{status: :initializing} = state) do
    {:reply, {:error, :already_initializing}, state}
  end

  def handle_call(:connect, _from, %{status: :closed} = state) do
    {:reply, {:error, :closed}, state}
  end

  # Ping works in any state (except closed)
  def handle_call(:ping, _from, %{status: :closed} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call(:ping, from, state) do
    {id, state} = next_id(state)
    send_request(state, id, Methods.ping(), %{})

    timeout_ref = schedule_timeout(id, state.request_timeout)
    state = put_pending(state, id, from, timeout_ref)

    {:noreply, state}
  end

  # All other operations require :ready status
  def handle_call(request, _from, %{status: status} = state) when status != :ready do
    case request do
      :close -> do_close(state)
      :get_transport -> {:reply, state.transport_pid, state}
      :get_status -> {:reply, state.status, state}
      :get_server_capabilities -> {:reply, state.server_capabilities, state}
      :get_server_info -> {:reply, state.server_info, state}
      _ -> {:reply, {:error, :not_ready}, state}
    end
  end

  def handle_call({:list_tools, opts}, from, state) do
    params = %{}
    params = if cursor = Keyword.get(opts, :cursor), do: Map.put(params, "cursor", cursor), else: params
    send_rpc(state, from, Methods.tools_list(), params)
  end

  def handle_call({:call_tool, name, arguments}, from, state) do
    params = %{"name" => name}
    params = if arguments && arguments != %{}, do: Map.put(params, "arguments", arguments), else: params
    send_rpc(state, from, Methods.tools_call(), params)
  end

  def handle_call({:list_resources, opts}, from, state) do
    params = %{}
    params = if cursor = Keyword.get(opts, :cursor), do: Map.put(params, "cursor", cursor), else: params
    send_rpc(state, from, Methods.resources_list(), params)
  end

  def handle_call({:read_resource, uri}, from, state) do
    send_rpc(state, from, Methods.resources_read(), %{"uri" => uri})
  end

  def handle_call({:list_resource_templates, opts}, from, state) do
    params = %{}
    params = if cursor = Keyword.get(opts, :cursor), do: Map.put(params, "cursor", cursor), else: params
    send_rpc(state, from, Methods.resources_templates_list(), params)
  end

  def handle_call({:subscribe_resource, uri}, from, state) do
    send_rpc(state, from, Methods.resources_subscribe(), %{"uri" => uri})
  end

  def handle_call({:unsubscribe_resource, uri}, from, state) do
    send_rpc(state, from, Methods.resources_unsubscribe(), %{"uri" => uri})
  end

  def handle_call({:list_prompts, opts}, from, state) do
    params = %{}
    params = if cursor = Keyword.get(opts, :cursor), do: Map.put(params, "cursor", cursor), else: params
    send_rpc(state, from, Methods.prompts_list(), params)
  end

  def handle_call({:get_prompt, name, arguments}, from, state) do
    params = %{"name" => name}
    params = if arguments && arguments != %{}, do: Map.put(params, "arguments", arguments), else: params
    send_rpc(state, from, Methods.prompts_get(), params)
  end

  def handle_call(:close, _from, state) do
    do_close(state)
  end

  def handle_call(:get_transport, _from, state) do
    {:reply, state.transport_pid, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:get_server_capabilities, _from, state) do
    {:reply, state.server_capabilities, state}
  end

  def handle_call(:get_server_info, _from, state) do
    {:reply, state.server_info, state}
  end

  # --- Incoming messages from transport ---

  @impl GenServer
  def handle_info({:mcp_message, message}, state) do
    case Protocol.decode_message(message) do
      {:ok, %Response{} = response} ->
        handle_response(response, state)

      {:ok, %Request{} = request} ->
        handle_server_request(request, state)

      {:ok, %Notification{} = notification} ->
        handle_notification(notification, state)

      {:error, error} ->
        Logger.warning("MCP Client: failed to decode message: #{inspect(error)}")
        {:noreply, state}
    end
  end

  def handle_info({:mcp_transport_closed, reason}, state) do
    Logger.debug("MCP Client: transport closed: #{inspect(reason)}")

    # Reply to all pending requests with an error
    Enum.each(state.pending_requests, fn {_id, {from, timeout_ref}} ->
      cancel_timeout(timeout_ref)
      GenServer.reply(from, {:error, {:transport_closed, reason}})
    end)

    # Reply to connect if pending
    state =
      if state.connect_from && state.status == :initializing do
        # connect_from is already in pending_requests, already replied above
        %{state | connect_from: nil}
      else
        state
      end

    {:noreply, %{state | status: :closed, pending_requests: %{}}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending_requests, id) do
      {{from, _timeout_ref}, pending} ->
        GenServer.reply(from, {:error, :timeout})

        state = %{state | pending_requests: pending}

        # If this was the initialize request, reset status
        state =
          if state.status == :initializing do
            %{state | status: :disconnected, connect_from: nil}
          else
            state
          end

        {:noreply, state}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("MCP Client: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.transport_pid && state.status != :closed do
      state.transport_module.close(state.transport_pid)
    end
  catch
    _, _ -> :ok
  end

  # --- Private helpers ---

  defp start_transport({module, opts}) do
    case module.start_link([{:owner, self()} | opts]) do
      {:ok, pid} -> {:ok, module, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_client_info(%Implementation{} = impl), do: impl

  defp build_client_info(map) when is_map(map) do
    %Implementation{
      name: Map.get(map, :name) || Map.get(map, "name", "mcp_ex"),
      version: Map.get(map, :version) || Map.get(map, "version", "0.1.0")
    }
  end

  defp next_id(state) do
    {state.next_id, %{state | next_id: state.next_id + 1}}
  end

  defp send_request(state, id, method, params) do
    message = Request.new(id, method, params)
    state.transport_module.send_message(state.transport_pid, Jason.decode!(Jason.encode!(message)))
  end

  defp send_notification(state, method, params \\ nil) do
    message = Notification.new(method, params)
    state.transport_module.send_message(state.transport_pid, Jason.decode!(Jason.encode!(message)))
  end

  defp send_rpc(state, from, method, params) do
    {id, state} = next_id(state)
    send_request(state, id, method, params)
    timeout_ref = schedule_timeout(id, state.request_timeout)
    state = put_pending(state, id, from, timeout_ref)
    {:noreply, state}
  end

  defp put_pending(state, id, from, timeout_ref) do
    %{state | pending_requests: Map.put(state.pending_requests, id, {from, timeout_ref})}
  end

  defp schedule_timeout(id, timeout_ms) do
    Process.send_after(self(), {:request_timeout, id}, timeout_ms)
  end

  defp cancel_timeout(ref) do
    Process.cancel_timer(ref)
  end

  defp handle_response(%Response{id: id} = response, state) do
    case Map.pop(state.pending_requests, id) do
      {{from, timeout_ref}, pending} ->
        cancel_timeout(timeout_ref)
        state = %{state | pending_requests: pending}

        if state.status == :initializing && state.connect_from == from do
          handle_init_response(response, from, state)
        else
          reply = parse_response(response)
          GenServer.reply(from, reply)
          {:noreply, state}
        end

      {nil, _} ->
        Logger.warning("MCP Client: received response for unknown request id=#{inspect(id)}")
        {:noreply, state}
    end
  end

  defp handle_init_response(%Response{error: error}, from, state) when error != nil do
    GenServer.reply(from, {:error, error})
    {:noreply, %{state | status: :disconnected, connect_from: nil}}
  end

  defp handle_init_response(%Response{result: result}, from, state) do
    init_result = Initialize.Result.from_map(result)

    # Send initialized notification
    send_notification(state, Methods.initialized())

    state = %{state |
      status: :ready,
      server_capabilities: init_result.capabilities,
      server_info: init_result.server_info,
      connect_from: nil
    }

    reply = {:ok, %{
      server_info: init_result.server_info,
      server_capabilities: init_result.capabilities,
      protocol_version: init_result.protocol_version,
      instructions: init_result.instructions
    }}

    GenServer.reply(from, reply)
    {:noreply, state}
  end

  defp parse_response(%Response{error: error}) when error != nil do
    {:error, error}
  end

  defp parse_response(%Response{result: result}) do
    {:ok, result}
  end

  defp handle_server_request(%Request{id: id, method: method, params: params}, state) do
    case Map.get(state.request_handlers, method) do
      nil ->
        # Send method not found error response
        error_response = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => Error.method_not_found_code(),
            "message" => "Method not found: #{method}"
          }
        }

        state.transport_module.send_message(state.transport_pid, error_response)
        {:noreply, state}

      handler when is_function(handler, 2) ->
        # Call handler with method and params, expect a result map
        result = handler.(method, params)
        send_response(state, id, result)
        {:noreply, state}

      handler when is_function(handler, 1) ->
        result = handler.(params)
        send_response(state, id, result)
        {:noreply, state}
    end
  end

  defp send_response(state, id, {:ok, result}) do
    response = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    state.transport_module.send_message(state.transport_pid, response)
  end

  defp send_response(state, id, {:error, %Error{} = error}) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => error.code, "message" => error.message, "data" => error.data}
    }

    state.transport_module.send_message(state.transport_pid, response)
  end

  defp handle_notification(%Notification{method: method, params: params}, state) do
    dispatch_notification(state.notification_handler, method, params)
    {:noreply, state}
  end

  defp dispatch_notification(nil, method, _params) do
    Logger.debug("MCP Client: unhandled notification: #{method}")
  end

  defp dispatch_notification(pid, method, params) when is_pid(pid) do
    send(pid, {:mcp_notification, method, params})
  end

  defp dispatch_notification(fun, method, params) when is_function(fun, 2) do
    fun.(method, params)
  end

  defp do_close(state) do
    if state.transport_pid do
      state.transport_module.close(state.transport_pid)
    end

    {:stop, :normal, :ok, %{state | status: :closed}}
  catch
    _, _ -> {:stop, :normal, :ok, %{state | status: :closed}}
  end

  defp init_result(state) do
    %{
      server_info: state.server_info,
      server_capabilities: state.server_capabilities,
      protocol_version: Protocol.protocol_version()
    }
  end

  defp list_all(client, operation, items_key, opts) do
    do_list_all(client, operation, items_key, opts, nil, [])
  end

  defp do_list_all(client, operation, items_key, opts, cursor, acc) do
    call_opts = if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts

    case apply_list_operation(client, operation, call_opts) do
      {:ok, result} ->
        items = Map.get(result, Atom.to_string(items_key), [])
        new_acc = acc ++ items

        case Map.get(result, "nextCursor") do
          nil -> {:ok, new_acc}
          next_cursor -> do_list_all(client, operation, items_key, opts, next_cursor, new_acc)
        end

      {:error, _} = error ->
        error
    end
  end

  defp apply_list_operation(client, :list_tools, opts), do: list_tools(client, opts)
  defp apply_list_operation(client, :list_resources, opts), do: list_resources(client, opts)

  defp apply_list_operation(client, :list_resource_templates, opts),
    do: list_resource_templates(client, opts)

  defp apply_list_operation(client, :list_prompts, opts), do: list_prompts(client, opts)
end
