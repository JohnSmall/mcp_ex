defmodule MCP.Transport.StreamableHTTP.Server do
  @moduledoc """
  Streamable HTTP server transport for MCP.

  A GenServer that implements the `MCP.Transport` behaviour, bridging
  between an HTTP Plug endpoint and the MCP.Server. Incoming HTTP
  requests are delivered to this transport, which forwards them to
  the MCP.Server. Outgoing messages from the MCP.Server are routed
  back to the appropriate HTTP response.

  Supports two modes for pending requests:

    * **Sync** — the Plug process blocks on `deliver_message/2` waiting
      for the response. Used for simple request/response.
    * **Stream** — the Plug process registers as a stream endpoint via
      `register_stream/3` and receives SSE events asynchronously. Used
      for tool calls that may send notifications/requests during execution.

  ## Options

    * `:owner` (required) — pid to receive `{:mcp_message, map}` and
      `{:mcp_transport_closed, reason}` messages
    * `:session_id` — the session ID for this transport
  """

  use GenServer

  require Logger

  @behaviour MCP.Transport

  alias MCP.Transport.SSE

  defstruct [
    :owner,
    :session_id,
    # %{request_id => {:sync, from} | {:stream, stream_pid}}
    :pending_responses,
    :sse_conn
  ]

  # --- Public API (Transport behaviour) ---

  @impl MCP.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl MCP.Transport
  def send_message(pid, message) when is_map(message) do
    GenServer.call(pid, {:send_message, message, []})
  end

  @doc """
  Sends a message with options. Supports `related_request_id` for
  routing notifications and requests to the correct SSE stream.
  """
  def send_message(pid, message, opts) when is_map(message) and is_list(opts) do
    GenServer.call(pid, {:send_message, message, opts})
  end

  @impl MCP.Transport
  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Delivers an incoming JSON-RPC message to this transport (synchronous).

  Called by the Plug when an HTTP POST arrives. For JSON-RPC requests,
  the caller blocks until the MCP.Server sends a response.

  Returns `{:ok, response_message}` for requests, or `:accepted` for
  notifications and responses.
  """
  def deliver_message(pid, message) do
    GenServer.call(pid, {:deliver_message, message}, 60_000)
  end

  @doc """
  Delivers an incoming JSON-RPC message to this transport (async).

  The message is forwarded to the MCP.Server but the caller does
  not block for a response. Used with `register_stream/3` for
  SSE streaming mode.
  """
  def deliver_message_async(pid, message) do
    GenServer.cast(pid, {:deliver_message_async, message})
  end

  @doc """
  Registers a Plug process as an SSE stream endpoint for a request.

  The Plug process will receive:
    * `{:sse_event, sse_encoded_data}` — intermediate SSE events
    * `{:sse_done, sse_encoded_data}` — final response event (stream should close)
  """
  def register_stream(pid, request_id, stream_pid) do
    GenServer.call(pid, {:register_stream, request_id, stream_pid})
  end

  @doc """
  Registers a Plug connection for SSE streaming (GET endpoint).

  Server-initiated messages will be streamed to this connection.
  """
  def register_sse_conn(pid, conn) do
    GenServer.call(pid, {:register_sse_conn, conn})
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    session_id = Keyword.get(opts, :session_id)

    state = %__MODULE__{
      owner: owner,
      session_id: session_id,
      pending_responses: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:deliver_message, message}, from, state) do
    is_request = Map.has_key?(message, "id") && Map.has_key?(message, "method")

    # Forward to MCP.Server
    send(state.owner, {:mcp_message, message})

    if is_request do
      request_id = Map.get(message, "id")
      pending = Map.put(state.pending_responses, request_id, {:sync, from})
      {:noreply, %{state | pending_responses: pending}}
    else
      {:reply, :accepted, state}
    end
  end

  def handle_call({:send_message, message, opts}, _from, state) do
    state = route_outgoing_message(message, opts, state)
    {:reply, :ok, state}
  end

  def handle_call({:register_stream, request_id, stream_pid}, _from, state) do
    pending = Map.put(state.pending_responses, request_id, {:stream, stream_pid})
    {:reply, :ok, %{state | pending_responses: pending}}
  end

  def handle_call({:register_sse_conn, conn}, _from, state) do
    {:reply, :ok, %{state | sse_conn: conn}}
  end

  def handle_call({:set_owner, new_owner}, _from, state) do
    {:reply, :ok, %{state | owner: new_owner}}
  end

  def handle_call(:close, _from, state) do
    # Notify any remaining stream endpoints
    Enum.each(state.pending_responses, fn
      {_id, {:stream, pid}} -> send(pid, {:sse_error, :transport_closed})
      _ -> :ok
    end)

    send(state.owner, {:mcp_transport_closed, :normal})
    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def handle_cast({:deliver_message_async, message}, state) do
    send(state.owner, {:mcp_message, message})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("MCP StreamableHTTP Server: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :ok
  end

  # --- Private helpers ---

  defp route_outgoing_message(message, opts, state) do
    response_id = Map.get(message, "id")
    is_response = response_id != nil && !Map.has_key?(message, "method")

    if is_response do
      route_response(response_id, message, state)
    else
      route_non_response(message, opts, state)
    end
  end

  defp route_response(response_id, message, state) do
    case Map.pop(state.pending_responses, response_id) do
      {nil, _pending} ->
        Logger.warning(
          "MCP StreamableHTTP Server: no pending request for response id=#{inspect(response_id)}"
        )

        state

      {{:sync, from}, pending} ->
        GenServer.reply(from, {:ok, message})
        %{state | pending_responses: pending}

      {{:stream, stream_pid}, pending} ->
        sse_data = SSE.encode_message(message)
        send(stream_pid, {:sse_done, sse_data})
        %{state | pending_responses: pending}
    end
  end

  defp route_non_response(message, opts, state) do
    related_request_id = Keyword.get(opts, :related_request_id)

    if related_request_id do
      route_to_related_stream(related_request_id, message, state)
    else
      Logger.debug(
        "MCP StreamableHTTP Server: server-initiated message (no related request): #{inspect(Map.get(message, "method", "unknown"))}"
      )

      state
    end
  end

  defp route_to_related_stream(related_request_id, message, state) do
    case Map.get(state.pending_responses, related_request_id) do
      {:stream, stream_pid} ->
        sse_data = SSE.encode_message(message)
        send(stream_pid, {:sse_event, sse_data})
        state

      _ ->
        Logger.debug(
          "MCP StreamableHTTP Server: no stream for related request #{inspect(related_request_id)}"
        )

        state
    end
  end
end
