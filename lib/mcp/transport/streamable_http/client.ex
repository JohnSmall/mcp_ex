defmodule MCP.Transport.StreamableHTTP.Client do
  @moduledoc """
  Streamable HTTP client transport for MCP.

  Sends JSON-RPC messages via HTTP POST and receives responses as either
  `application/json` or `text/event-stream` (SSE). Optionally opens a
  GET SSE stream for server-initiated messages.

  ## Options

    * `:owner` (required) — pid to receive `{:mcp_message, map}` and
      `{:mcp_transport_closed, reason}` messages
    * `:url` (required) — the MCP endpoint URL (e.g., "http://localhost:8080/mcp")
    * `:headers` — extra HTTP headers to include on all requests
    * `:protocol_version` — MCP protocol version (default: "2025-11-25")

  ## Session Management

  The client automatically extracts the `MCP-Session-Id` header from the
  server's initialize response and includes it in all subsequent requests.
  On close, it sends an HTTP DELETE to terminate the session.
  """

  use GenServer

  require Logger

  alias MCP.Transport.SSE

  @behaviour MCP.Transport

  @protocol_version "2025-11-25"

  defstruct [
    :owner,
    :url,
    :session_id,
    :protocol_version,
    :extra_headers,
    :sse_task
  ]

  # --- Public API (Transport behaviour) ---

  @impl MCP.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl MCP.Transport
  def send_message(pid, message) when is_map(message) do
    GenServer.call(pid, {:send_message, message}, 60_000)
  end

  @impl MCP.Transport
  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    url = Keyword.fetch!(opts, :url)
    protocol_version = Keyword.get(opts, :protocol_version, @protocol_version)
    extra_headers = Keyword.get(opts, :headers, [])

    state = %__MODULE__{
      owner: owner,
      url: url,
      protocol_version: protocol_version,
      extra_headers: extra_headers
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:send_message, message}, _from, state) do
    # Send HTTP POST with the JSON-RPC message
    case do_post(state, message) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, state) do
    do_close(state)
    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def handle_info({:sse_event, event}, state) do
    # SSE event received from a background stream (GET or POST SSE response)
    case Map.get(event, :data) do
      nil ->
        {:noreply, state}

      "" ->
        # Priming event with empty data — ignore
        {:noreply, state}

      data ->
        case Jason.decode(data) do
          {:ok, decoded} ->
            send(state.owner, {:mcp_message, decoded})

          {:error, reason} ->
            Logger.warning(
              "MCP StreamableHTTP Client: failed to decode SSE data: #{inspect(reason)}"
            )
        end

        {:noreply, state}
    end
  end

  def handle_info({:sse_stream_closed, reason}, state) do
    Logger.debug("MCP StreamableHTTP Client: SSE stream closed: #{inspect(reason)}")
    {:noreply, %{state | sse_task: nil}}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Task completion message — ignore (we handle via :DOWN)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("MCP StreamableHTTP Client: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    do_close(state)
    :ok
  end

  # --- Private helpers ---

  defp do_post(state, message) do
    headers = build_headers(state)
    body = Jason.encode!(message)

    case Req.post(state.url, body: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}}
      when status in [200, 201] ->
        # Check for session ID in response headers
        new_state = maybe_extract_session_id(state, resp_headers)
        content_type = get_content_type(resp_headers)

        cond do
          String.contains?(content_type, "text/event-stream") ->
            # Parse SSE events from the response body
            parse_sse_body(new_state, resp_body)

          String.contains?(content_type, "application/json") ->
            # Single JSON response
            deliver_json_response(new_state, resp_body)

          true ->
            Logger.warning(
              "MCP StreamableHTTP Client: unexpected content-type: #{content_type}"
            )

            {:ok, new_state}
        end

      {:ok, %Req.Response{status: 202}} ->
        # Accepted (notification/response acknowledged)
        {:ok, state}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.warning(
          "MCP StreamableHTTP Client: HTTP #{status}: #{inspect(resp_body)}"
        )

        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        Logger.warning(
          "MCP StreamableHTTP Client: POST failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp build_headers(state) do
    base = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", state.protocol_version}
    ]

    base =
      if state.session_id do
        [{"mcp-session-id", state.session_id} | base]
      else
        base
      end

    base ++ state.extra_headers
  end

  defp maybe_extract_session_id(state, resp_headers) do
    case get_header(resp_headers, "mcp-session-id") do
      nil -> state
      session_id -> %{state | session_id: session_id}
    end
  end

  defp get_content_type(headers) do
    get_header(headers, "content-type") || ""
  end

  defp get_header(headers, name) do
    # Req returns headers as a map of %{name => [values]}
    case headers do
      %{^name => [value | _]} -> value
      _ -> nil
    end
  end

  defp parse_sse_body(state, body) when is_binary(body) do
    # Parse complete SSE body (from a non-streaming response)
    {events, _parser} = SSE.feed(SSE.new_parser(), body)

    Enum.each(events, fn event ->
      case Map.get(event, :data) do
        nil -> :ok
        "" -> :ok
        data -> deliver_decoded(state.owner, data)
      end
    end)

    {:ok, state}
  end

  defp deliver_json_response(state, body) when is_map(body) do
    send(state.owner, {:mcp_message, body})
    {:ok, state}
  end

  defp deliver_json_response(state, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        send(state.owner, {:mcp_message, decoded})
        {:ok, state}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp deliver_decoded(owner, data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} ->
        send(owner, {:mcp_message, decoded})

      {:error, reason} ->
        Logger.warning(
          "MCP StreamableHTTP Client: failed to decode JSON from SSE: #{inspect(reason)}"
        )
    end
  end

  defp do_close(state) do
    # Send DELETE to terminate session if we have a session ID
    if state.session_id do
      headers = [
        {"mcp-session-id", state.session_id},
        {"mcp-protocol-version", state.protocol_version}
      ]

      # Best-effort DELETE, ignore errors
      Req.delete(state.url, headers: headers)
    end
  catch
    _, _ -> :ok
  end
end
