defmodule MCP.Server do
  @moduledoc """
  MCP server implementation.

  A GenServer that handles incoming MCP client requests via a pluggable
  transport. Routes requests to a handler module implementing the
  `MCP.Server.Handler` behaviour.

  ## Usage

      defmodule MyHandler do
        @behaviour MCP.Server.Handler

        @impl true
        def init(_opts), do: {:ok, %{}}

        @impl true
        def handle_list_tools(_cursor, state) do
          tools = [%{"name" => "echo", "description" => "Echoes input"}]
          {:ok, tools, nil, state}
        end

        @impl true
        def handle_call_tool("echo", %{"message" => msg}, state) do
          {:ok, [%{"type" => "text", "text" => msg}], state}
        end
      end

      {:ok, server} = MCP.Server.start_link(
        transport: {MCP.Transport.Stdio, mode: :server},
        handler: {MyHandler, []},
        server_info: %{name: "my_server", version: "1.0.0"}
      )

  ## Options

    * `:transport` — `{module, opts}` transport spec. The server starts the
      transport in its init, setting itself as the owner.
    * `:handler` — `{module, opts}` handler spec. The module must implement
      `MCP.Server.Handler`.
    * `:server_info` — `%Implementation{}` or map with `:name` and `:version`.
    * `:instructions` — optional string instructions for the client.
    * `:request_timeout` — default timeout in ms for server-initiated
      requests (default: 30_000).
  """

  use GenServer

  require Logger

  alias MCP.Protocol

  alias MCP.Protocol.Capabilities.{
    CompletionCapabilities,
    LoggingCapabilities,
    PromptCapabilities,
    ResourceCapabilities,
    ServerCapabilities,
    ToolCapabilities
  }

  alias MCP.Protocol.Error
  alias MCP.Protocol.Messages.{Initialize, Notification, Request, Response}
  alias MCP.Protocol.Methods
  alias MCP.Protocol.Types.Implementation
  alias MCP.Server.ToolContext

  defstruct [
    :handler_module,
    :handler_state,
    :transport_module,
    :transport_pid,
    :client_capabilities,
    :client_info,
    :server_info,
    :capabilities,
    :instructions,
    :status,
    :pending_requests,
    :next_id,
    :request_timeout,
    :log_level,
    :has_async_tools,
    :async_tool_tasks
  ]

  @default_request_timeout 30_000

  # --- Public API ---

  @doc """
  Starts the server GenServer and its transport.
  """
  def start_link(opts) do
    {gen_opts, server_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, server_opts, gen_opts)
  end

  @doc """
  Returns the transport pid (useful for testing with MockTransport).
  """
  def transport(server) do
    GenServer.call(server, :get_transport)
  end

  @doc """
  Returns the current server status.
  """
  def status(server) do
    GenServer.call(server, :get_status)
  end

  @doc """
  Returns the client capabilities from initialization.
  """
  def client_capabilities(server) do
    GenServer.call(server, :get_client_capabilities)
  end

  @doc """
  Returns the client info from initialization.
  """
  def client_info(server) do
    GenServer.call(server, :get_client_info)
  end

  @doc """
  Sends a `notifications/tools/list_changed` notification to the client.
  """
  def notify_tools_changed(server) do
    GenServer.cast(server, {:notify, Methods.tools_list_changed(), nil})
  end

  @doc """
  Sends a `notifications/resources/list_changed` notification to the client.
  """
  def notify_resources_changed(server) do
    GenServer.cast(server, {:notify, Methods.resources_list_changed(), nil})
  end

  @doc """
  Sends a `notifications/resources/updated` notification for a specific URI.
  """
  def notify_resource_updated(server, uri) do
    GenServer.cast(server, {:notify, Methods.resources_updated(), %{"uri" => uri}})
  end

  @doc """
  Sends a `notifications/prompts/list_changed` notification to the client.
  """
  def notify_prompts_changed(server) do
    GenServer.cast(server, {:notify, Methods.prompts_list_changed(), nil})
  end

  @doc """
  Sends a log message notification to the client.

  Respects the log level set by the client via `logging/setLevel`.
  Messages below the current level are silently dropped.
  """
  def log(server, level, data, logger_name \\ nil) do
    GenServer.cast(server, {:log, level, data, logger_name})
  end

  @doc """
  Sends a progress notification to the client.
  """
  def send_progress(server, progress_token, progress, total \\ nil) do
    params = %{"progressToken" => progress_token, "progress" => progress}
    params = if total, do: Map.put(params, "total", total), else: params
    GenServer.cast(server, {:notify, Methods.progress(), params})
  end

  @doc """
  Sends a `sampling/createMessage` request to the client.

  Returns `{:ok, result}` or `{:error, reason}`.
  Requires the client to have declared sampling capability.
  """
  def request_sampling(server, params, timeout \\ 60_000) do
    GenServer.call(server, {:request_client, Methods.sampling_create_message(), params}, timeout)
  end

  @doc """
  Sends a `roots/list` request to the client.

  Returns `{:ok, result}` or `{:error, reason}`.
  Requires the client to have declared roots capability.
  """
  def request_roots(server, timeout \\ 30_000) do
    GenServer.call(server, {:request_client, Methods.roots_list(), %{}}, timeout)
  end

  @doc """
  Sends an `elicitation/create` request to the client.

  Returns `{:ok, result}` or `{:error, reason}`.
  Requires the client to have declared elicitation capability.
  """
  def request_elicitation(server, params, timeout \\ 60_000) do
    GenServer.call(server, {:request_client, Methods.elicitation_create(), params}, timeout)
  end

  @doc """
  Closes the server and its transport.
  """
  def close(server) do
    GenServer.call(server, :close)
  catch
    :exit, _ -> :ok
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    {transport_spec, opts} = Keyword.pop!(opts, :transport)
    {handler_spec, opts} = Keyword.pop!(opts, :handler)

    server_info =
      build_server_info(Keyword.get(opts, :server_info, %{name: "mcp_ex", version: "0.1.0"}))

    instructions = Keyword.get(opts, :instructions)
    request_timeout = Keyword.get(opts, :request_timeout, @default_request_timeout)

    {handler_module, handler_opts} = handler_spec
    capabilities = detect_capabilities(handler_module)
    has_async_tools = has_async_tool_handler?(handler_module)

    case handler_module.init(handler_opts) do
      {:ok, handler_state} ->
        case start_transport(transport_spec) do
          {:ok, module, pid} ->
            state = %__MODULE__{
              handler_module: handler_module,
              handler_state: handler_state,
              transport_module: module,
              transport_pid: pid,
              server_info: server_info,
              capabilities: capabilities,
              instructions: instructions,
              status: :waiting,
              pending_requests: %{},
              next_id: 1,
              request_timeout: request_timeout,
              has_async_tools: has_async_tools,
              async_tool_tasks: %{}
            }

            {:ok, state}

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, {:handler_init_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:get_transport, _from, state) do
    {:reply, state.transport_pid, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:get_client_capabilities, _from, state) do
    {:reply, state.client_capabilities, state}
  end

  def handle_call(:get_client_info, _from, state) do
    {:reply, state.client_info, state}
  end

  def handle_call(:close, _from, state) do
    do_close(state)
  end

  def handle_call({:request_client, method, params}, from, %{status: :ready} = state) do
    {id, state} = next_id(state)
    send_request(state, id, method, params)
    timeout_ref = schedule_timeout(id, state.request_timeout)
    state = put_pending(state, id, from, timeout_ref)
    {:noreply, state}
  end

  def handle_call({:request_client, _method, _params}, _from, %{status: status} = state) do
    {:reply, {:error, {:not_ready, status}}, state}
  end

  # Context calls from async tool handlers
  def handle_call({:context_notify, related_request_id, method, params}, _from, state) do
    send_notification(state, method, params, related_request_id: related_request_id)
    {:reply, :ok, state}
  end

  def handle_call({:context_request, related_request_id, method, params}, from, state) do
    {id, state} = next_id(state)
    send_request(state, id, method, params, related_request_id: related_request_id)
    timeout_ref = schedule_timeout(id, state.request_timeout)
    state = put_pending(state, id, from, timeout_ref)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:notify, method, params}, %{status: :ready} = state) do
    send_notification(state, method, params)
    {:noreply, state}
  end

  def handle_cast({:notify, _method, _params}, state) do
    {:noreply, state}
  end

  def handle_cast({:log, level, data, logger_name}, %{status: :ready} = state) do
    if should_log?(level, state.log_level) do
      params = %{"level" => level, "data" => data}
      params = if logger_name, do: Map.put(params, "logger", logger_name), else: params
      send_notification(state, Methods.logging_message(), params)
    end

    {:noreply, state}
  end

  def handle_cast({:log, _level, _data, _logger_name}, state) do
    {:noreply, state}
  end

  # --- Incoming messages from transport ---

  @impl GenServer
  def handle_info({:mcp_message, message}, state) do
    case Protocol.decode_message(message) do
      {:ok, %Request{} = request} ->
        handle_client_request(request, state)

      {:ok, %Notification{} = notification} ->
        handle_client_notification(notification, state)

      {:ok, %Response{} = response} ->
        handle_client_response(response, state)

      {:error, error} ->
        Logger.warning("MCP Server: failed to decode message: #{inspect(error)}")
        {:noreply, state}
    end
  end

  def handle_info({:mcp_transport_closed, reason}, state) do
    Logger.debug("MCP Server: transport closed: #{inspect(reason)}")

    Enum.each(state.pending_requests, fn {_id, {from, timeout_ref}} ->
      cancel_timeout(timeout_ref)
      GenServer.reply(from, {:error, {:transport_closed, reason}})
    end)

    {:noreply, %{state | status: :closed, pending_requests: %{}}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending_requests, id) do
      {{from, _timeout_ref}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending_requests: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  # Async tool task completion (Task.async sends {ref, result})
  def handle_info({ref, result}, state) when is_reference(ref) do
    case find_async_task(state, ref) do
      {request_id, _task_pid} ->
        Process.demonitor(ref, [:flush])
        state = remove_async_task(state, request_id)
        handle_async_tool_result(request_id, result, state)

      nil ->
        Logger.debug("MCP Server: unexpected ref message: #{inspect(ref)}")
        {:noreply, state}
    end
  end

  # Task DOWN message (process exited abnormally)
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_async_task(state, ref) do
      {request_id, _task_pid} ->
        state = remove_async_task(state, request_id)
        send_error_response(state, request_id, %Error{code: -32_603, message: "Tool execution failed: #{inspect(reason)}"})
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("MCP Server: unexpected message: #{inspect(msg)}")
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

  # --- Request handling ---

  defp handle_client_request(%Request{id: id, method: "initialize", params: params}, state) do
    handle_initialize(id, params, state)
  end

  defp handle_client_request(%Request{id: id, method: "ping"}, state) do
    send_success_response(state, id, %{})
    {:noreply, state}
  end

  # All other requests require :ready status
  defp handle_client_request(%Request{id: id} = request, %{status: :ready} = state) do
    route_request(request, id, state)
  end

  defp handle_client_request(%Request{id: id}, state) do
    send_error_response(state, id, Error.invalid_request("Server not initialized"))
    {:noreply, state}
  end

  # --- Notification handling ---

  defp handle_client_notification(
         %Notification{method: "notifications/initialized"},
         %{status: :waiting} = state
       ) do
    {:noreply, %{state | status: :ready}}
  end

  defp handle_client_notification(
         %Notification{method: "notifications/cancelled", params: params},
         state
       ) do
    Logger.debug("MCP Server: received cancellation for request #{inspect(params)}")
    {:noreply, state}
  end

  defp handle_client_notification(%Notification{method: method}, state) do
    Logger.debug("MCP Server: unhandled notification: #{method}")
    {:noreply, state}
  end

  # --- Response handling (for server-initiated requests) ---

  defp handle_client_response(%Response{id: id} = response, state) do
    case Map.pop(state.pending_requests, id) do
      {{from, timeout_ref}, pending} ->
        cancel_timeout(timeout_ref)
        state = %{state | pending_requests: pending}

        reply =
          if response.error do
            {:error, response.error}
          else
            {:ok, response.result}
          end

        GenServer.reply(from, reply)
        {:noreply, state}

      {nil, _} ->
        Logger.warning("MCP Server: received response for unknown request id=#{inspect(id)}")
        {:noreply, state}
    end
  end

  # --- Initialization ---

  defp handle_initialize(id, params, %{status: :waiting} = state) do
    init_params = Initialize.Params.from_map(params)

    result =
      Initialize.Result.to_map(%Initialize.Result{
        protocol_version: negotiate_version(init_params.protocol_version),
        capabilities: state.capabilities,
        server_info: state.server_info,
        instructions: state.instructions
      })

    send_success_response(state, id, result)

    state = %{
      state
      | client_capabilities: init_params.capabilities,
        client_info: init_params.client_info
    }

    {:noreply, state}
  end

  defp handle_initialize(id, _params, %{status: :ready} = state) do
    send_error_response(state, id, Error.invalid_request("Already initialized"))
    {:noreply, state}
  end

  defp handle_initialize(id, _params, state) do
    send_error_response(state, id, Error.invalid_request("Invalid server state"))
    {:noreply, state}
  end

  # --- Request routing ---

  defp route_request(%Request{method: "tools/list", params: params}, id, state),
    do: handle_tools_list(id, params, state)

  defp route_request(%Request{method: "tools/call", params: params}, id, state),
    do: handle_tools_call(id, params, state)

  defp route_request(%Request{method: "resources/list", params: params}, id, state),
    do: handle_resources_list(id, params, state)

  defp route_request(%Request{method: "resources/read", params: params}, id, state),
    do: handle_resources_read(id, params, state)

  defp route_request(%Request{method: "resources/subscribe", params: params}, id, state),
    do: handle_resources_subscribe(id, params, state)

  defp route_request(%Request{method: "resources/unsubscribe", params: params}, id, state),
    do: handle_resources_unsubscribe(id, params, state)

  defp route_request(%Request{method: "resources/templates/list", params: params}, id, state),
    do: handle_resources_templates_list(id, params, state)

  defp route_request(%Request{method: "prompts/list", params: params}, id, state),
    do: handle_prompts_list(id, params, state)

  defp route_request(%Request{method: "prompts/get", params: params}, id, state),
    do: handle_prompts_get(id, params, state)

  defp route_request(%Request{method: "completion/complete", params: params}, id, state),
    do: handle_completion(id, params, state)

  defp route_request(%Request{method: "logging/setLevel", params: params}, id, state),
    do: handle_set_log_level(id, params, state)

  defp route_request(%Request{method: method}, id, state) do
    send_error_response(state, id, Error.method_not_found(method))
    {:noreply, state}
  end

  defp handle_tools_list(id, params, state) do
    cursor = get_in_params(params, "cursor")

    case state.handler_module.handle_list_tools(cursor, state.handler_state) do
      {:ok, tools, next_cursor, handler_state} ->
        result = %{"tools" => tools}
        result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
        send_success_response(state, id, result)
        {:noreply, %{state | handler_state: handler_state}}
    end
  end

  defp handle_tools_call(id, params, state) do
    name = Map.get(params || %{}, "name", "")
    arguments = Map.get(params || %{}, "arguments", %{})
    meta = Map.get(params || %{}, "_meta")

    if state.has_async_tools do
      handle_tools_call_async(id, name, arguments, meta, state)
    else
      handle_tools_call_sync(id, name, arguments, state)
    end
  end

  defp handle_tools_call_sync(id, name, arguments, state) do
    case state.handler_module.handle_call_tool(name, arguments, state.handler_state) do
      {:ok, content, handler_state} ->
        send_success_response(state, id, %{"content" => content})
        {:noreply, %{state | handler_state: handler_state}}

      {:ok, content, is_error, handler_state} ->
        result = %{"content" => content}
        result = if is_error, do: Map.put(result, "isError", true), else: result
        send_success_response(state, id, result)
        {:noreply, %{state | handler_state: handler_state}}

      {:error, code, message, handler_state} ->
        send_error_response(state, id, %Error{code: code, message: message})
        {:noreply, %{state | handler_state: handler_state}}
    end
  end

  defp handle_tools_call_async(id, name, arguments, meta, state) do
    server_pid = self()
    handler_module = state.handler_module
    handler_state = state.handler_state

    context = %ToolContext{
      server_pid: server_pid,
      request_id: id,
      meta: meta
    }

    task =
      Task.async(fn ->
        handler_module.handle_call_tool(name, arguments, context, handler_state)
      end)

    async_tasks = Map.put(state.async_tool_tasks, id, {task.ref, task.pid})
    {:noreply, %{state | async_tool_tasks: async_tasks}}
  end

  defp handle_resources_list(id, params, state) do
    cursor = get_in_params(params, "cursor")

    case state.handler_module.handle_list_resources(cursor, state.handler_state) do
      {:ok, resources, next_cursor, handler_state} ->
        result = %{"resources" => resources}
        result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
        send_success_response(state, id, result)
        {:noreply, %{state | handler_state: handler_state}}
    end
  end

  defp handle_resources_read(id, params, state) do
    uri = Map.get(params || %{}, "uri", "")

    case state.handler_module.handle_read_resource(uri, state.handler_state) do
      {:ok, contents, handler_state} ->
        send_success_response(state, id, %{"contents" => contents})
        {:noreply, %{state | handler_state: handler_state}}

      {:error, code, message, handler_state} ->
        send_error_response(state, id, %Error{code: code, message: message})
        {:noreply, %{state | handler_state: handler_state}}
    end
  end

  defp handle_resources_subscribe(id, params, state) do
    uri = Map.get(params || %{}, "uri", "")

    case state.handler_module.handle_subscribe(uri, state.handler_state) do
      {:ok, handler_state} ->
        send_success_response(state, id, %{})
        {:noreply, %{state | handler_state: handler_state}}

      {:error, code, message, handler_state} ->
        send_error_response(state, id, %Error{code: code, message: message})
        {:noreply, %{state | handler_state: handler_state}}
    end
  end

  defp handle_resources_unsubscribe(id, params, state) do
    uri = Map.get(params || %{}, "uri", "")

    case state.handler_module.handle_unsubscribe(uri, state.handler_state) do
      {:ok, handler_state} ->
        send_success_response(state, id, %{})
        {:noreply, %{state | handler_state: handler_state}}

      {:error, code, message, handler_state} ->
        send_error_response(state, id, %Error{code: code, message: message})
        {:noreply, %{state | handler_state: handler_state}}
    end
  end

  defp handle_resources_templates_list(id, params, state) do
    cursor = get_in_params(params, "cursor")

    case state.handler_module.handle_list_resource_templates(cursor, state.handler_state) do
      {:ok, templates, next_cursor, handler_state} ->
        result = %{"resourceTemplates" => templates}
        result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
        send_success_response(state, id, result)
        {:noreply, %{state | handler_state: handler_state}}
    end
  end

  defp handle_prompts_list(id, params, state) do
    cursor = get_in_params(params, "cursor")

    case state.handler_module.handle_list_prompts(cursor, state.handler_state) do
      {:ok, prompts, next_cursor, handler_state} ->
        result = %{"prompts" => prompts}
        result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
        send_success_response(state, id, result)
        {:noreply, %{state | handler_state: handler_state}}
    end
  end

  defp handle_prompts_get(id, params, state) do
    name = Map.get(params || %{}, "name", "")
    arguments = Map.get(params || %{}, "arguments")

    case state.handler_module.handle_get_prompt(name, arguments, state.handler_state) do
      {:ok, result, handler_state} ->
        send_success_response(state, id, result)
        {:noreply, %{state | handler_state: handler_state}}

      {:error, code, message, handler_state} ->
        send_error_response(state, id, %Error{code: code, message: message})
        {:noreply, %{state | handler_state: handler_state}}
    end
  end

  defp handle_completion(id, params, state) do
    ref = Map.get(params || %{}, "ref", %{})
    argument = Map.get(params || %{}, "argument", %{})

    case state.handler_module.handle_complete(ref, argument, state.handler_state) do
      {:ok, completion, handler_state} ->
        send_success_response(state, id, %{"completion" => completion})
        {:noreply, %{state | handler_state: handler_state}}
    end
  end

  defp handle_set_log_level(id, params, state) do
    level = Map.get(params || %{}, "level", "info")

    case state.handler_module.handle_set_log_level(level, state.handler_state) do
      {:ok, handler_state} ->
        send_success_response(state, id, %{})
        {:noreply, %{state | handler_state: handler_state, log_level: level}}
    end
  end

  # --- Private helpers ---

  defp start_transport({module, opts}) do
    case module.start_link([{:owner, self()} | opts]) do
      {:ok, pid} -> {:ok, module, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_server_info(%Implementation{} = impl), do: impl

  defp build_server_info(map) when is_map(map) do
    %Implementation{
      name: Map.get(map, :name) || Map.get(map, "name", "mcp_ex"),
      version: Map.get(map, :version) || Map.get(map, "version", "0.1.0")
    }
  end

  defp detect_capabilities(handler_module) do
    callbacks = handler_module.__info__(:functions)

    %ServerCapabilities{
      tools: if({:handle_list_tools, 2} in callbacks, do: %ToolCapabilities{list_changed: true}),
      resources: detect_resource_capabilities(callbacks),
      prompts:
        if({:handle_list_prompts, 2} in callbacks, do: %PromptCapabilities{list_changed: true}),
      logging: if({:handle_set_log_level, 2} in callbacks, do: %LoggingCapabilities{}),
      completions: if({:handle_complete, 3} in callbacks, do: %CompletionCapabilities{})
    }
  end

  defp detect_resource_capabilities(callbacks) do
    has_resources = {:handle_list_resources, 2} in callbacks
    has_subscribe = {:handle_subscribe, 2} in callbacks

    if has_resources do
      %ResourceCapabilities{
        list_changed: true,
        subscribe: if(has_subscribe, do: true)
      }
    end
  end

  defp negotiate_version(client_version) do
    supported = Protocol.protocol_version()

    if client_version == supported do
      supported
    else
      supported
    end
  end

  defp next_id(state) do
    {state.next_id, %{state | next_id: state.next_id + 1}}
  end

  defp send_request(state, id, method, params, opts \\ []) do
    message = Request.new(id, method, params)
    encoded = Jason.decode!(Jason.encode!(message))
    send_message_to_transport(state, encoded, opts)
  end

  defp send_notification(state, method, params, opts \\ []) do
    message = Notification.new(method, params)
    encoded = Jason.decode!(Jason.encode!(message))
    send_message_to_transport(state, encoded, opts)
  end

  defp send_success_response(state, id, result, opts \\ []) do
    response = Response.success(id, result)
    encoded = Jason.decode!(Jason.encode!(response))
    send_message_to_transport(state, encoded, opts)
  end

  defp send_error_response(state, id, %Error{} = error, opts \\ []) do
    response = Response.error(id, error)
    encoded = Jason.decode!(Jason.encode!(response))
    send_message_to_transport(state, encoded, opts)
  end

  defp send_message_to_transport(state, message, opts) do
    if opts != [] && function_exported?(state.transport_module, :send_message, 3) do
      state.transport_module.send_message(state.transport_pid, message, opts)
    else
      state.transport_module.send_message(state.transport_pid, message)
    end
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

  defp get_in_params(nil, _key), do: nil
  defp get_in_params(params, key), do: Map.get(params, key)

  @log_levels ~w(debug info notice warning error critical alert emergency)

  defp should_log?(_level, nil), do: false

  defp should_log?(level, threshold) do
    level_index = Enum.find_index(@log_levels, &(&1 == level)) || 0
    threshold_index = Enum.find_index(@log_levels, &(&1 == threshold)) || 0
    level_index >= threshold_index
  end

  defp has_async_tool_handler?(handler_module) do
    {:handle_call_tool, 4} in handler_module.__info__(:functions)
  end

  defp find_async_task(state, ref) do
    Enum.find_value(state.async_tool_tasks, fn {request_id, {task_ref, task_pid}} ->
      if task_ref == ref, do: {request_id, task_pid}
    end)
  end

  defp remove_async_task(state, request_id) do
    %{state | async_tool_tasks: Map.delete(state.async_tool_tasks, request_id)}
  end

  defp handle_async_tool_result(request_id, result, state) do
    case result do
      {:ok, content, handler_state} ->
        send_success_response(state, request_id, %{"content" => content})
        {:noreply, %{state | handler_state: handler_state}}

      {:ok, content, is_error, handler_state} ->
        result_map = %{"content" => content}
        result_map = if is_error, do: Map.put(result_map, "isError", true), else: result_map
        send_success_response(state, request_id, result_map)
        {:noreply, %{state | handler_state: handler_state}}

      {:error, code, message, handler_state} ->
        send_error_response(state, request_id, %Error{code: code, message: message})
        {:noreply, %{state | handler_state: handler_state}}
    end
  end

  defp do_close(state) do
    if state.transport_pid do
      state.transport_module.close(state.transport_pid)
    end

    {:stop, :normal, :ok, %{state | status: :closed}}
  catch
    _, _ -> {:stop, :normal, :ok, %{state | status: :closed}}
  end
end
