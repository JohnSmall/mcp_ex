defmodule MCP.Transport.StreamableHTTP.Server do
  @moduledoc """
  Streamable HTTP server transport for MCP.

  A GenServer that implements the `MCP.Transport` behaviour, bridging
  between an HTTP Plug endpoint and the MCP.Server. Incoming HTTP
  requests are delivered to this transport, which forwards them to
  the MCP.Server. Outgoing messages from the MCP.Server are routed
  back to the appropriate HTTP response.

  This transport is not started directly — it is created by
  `MCP.Transport.StreamableHTTP.Plug` when a new session is established.

  ## Options

    * `:owner` (required) — pid to receive `{:mcp_message, map}` and
      `{:mcp_transport_closed, reason}` messages
    * `:session_id` — the session ID for this transport
  """

  use GenServer

  require Logger

  @behaviour MCP.Transport

  defstruct [
    :owner,
    :session_id,
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
    GenServer.call(pid, {:send_message, message})
  end

  @impl MCP.Transport
  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Delivers an incoming JSON-RPC message to this transport.

  Called by the Plug when an HTTP POST arrives. For JSON-RPC requests,
  the caller blocks until the MCP.Server sends a response.

  Returns `{:ok, response_message}` for requests, or `:accepted` for
  notifications and responses.
  """
  def deliver_message(pid, message) do
    GenServer.call(pid, {:deliver_message, message}, 60_000)
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
    # Determine if this is a request (has an "id" and "method" field)
    is_request = Map.has_key?(message, "id") && Map.has_key?(message, "method")

    # Forward to MCP.Server
    send(state.owner, {:mcp_message, message})

    if is_request do
      # Store the caller reference so we can reply when the response comes back
      request_id = Map.get(message, "id")
      pending = Map.put(state.pending_responses, request_id, from)
      {:noreply, %{state | pending_responses: pending}}
    else
      # Notifications and responses don't get a reply — immediately accept
      {:reply, :accepted, state}
    end
  end

  def handle_call({:send_message, message}, _from, state) do
    # MCP.Server is sending a message out (response, notification, or request)
    state = route_outgoing_message(message, state)
    {:reply, :ok, state}
  end

  def handle_call({:register_sse_conn, conn}, _from, state) do
    {:reply, :ok, %{state | sse_conn: conn}}
  end

  def handle_call({:set_owner, new_owner}, _from, state) do
    {:reply, :ok, %{state | owner: new_owner}}
  end

  def handle_call(:close, _from, state) do
    send(state.owner, {:mcp_transport_closed, :normal})
    {:stop, :normal, :ok, state}
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

  defp route_outgoing_message(message, state) do
    # Check if this is a response (has "id" but no "method")
    response_id = Map.get(message, "id")
    is_response = response_id != nil && !Map.has_key?(message, "method")

    if is_response do
      # Route to the pending HTTP caller
      case Map.pop(state.pending_responses, response_id) do
        {nil, _pending} ->
          Logger.warning(
            "MCP StreamableHTTP Server: no pending request for response id=#{inspect(response_id)}"
          )

          state

        {from, pending} ->
          GenServer.reply(from, {:ok, message})
          %{state | pending_responses: pending}
      end
    else
      # Server-initiated notification or request — would go to SSE stream
      # For now, log a warning if no SSE connection is available
      Logger.debug(
        "MCP StreamableHTTP Server: server-initiated message (no SSE routing): #{inspect(Map.get(message, "method", "unknown"))}"
      )

      state
    end
  end
end
