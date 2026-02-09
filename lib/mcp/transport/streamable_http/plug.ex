defmodule MCP.Transport.StreamableHTTP.Plug do
  @moduledoc """
  Plug endpoint for the MCP Streamable HTTP transport.

  Handles POST, GET, and DELETE HTTP methods at the MCP endpoint:

    * **POST** — receive JSON-RPC messages from clients, route to the
      appropriate MCP.Server session, and return the response
    * **GET** — open an SSE stream for server-initiated messages
    * **DELETE** — terminate a session

  ## Usage

  Mount this Plug in your HTTP server (e.g., with Bandit):

      # Create a Plug with a server factory function
      plug = MCP.Transport.StreamableHTTP.Plug.new(
        server_mod: MyApp.McpHandler,
        server_opts: []
      )

      # Start Bandit with the Plug
      {:ok, _} = Bandit.start_link(plug: plug, port: 8080)

  ## Options

    * `:server_mod` (required) — the MCP.Server.Handler module
    * `:server_opts` — options to pass to `MCP.Server.start_link/1`
    * `:session_id_generator` — function that generates session IDs
      (default: `UUID.uuid4/0`). Pass `nil` for stateless mode.
    * `:enable_json_response` — if true, return `application/json` instead
      of SSE for simple request/response (default: false)
    * `:protocol_version` — expected protocol version (default: "2025-11-25")
  """

  @behaviour Plug

  require Logger

  alias MCP.Transport.SSE
  alias MCP.Transport.StreamableHTTP.Server, as: HTTPTransport

  @protocol_version "2025-11-25"

  defstruct [
    :server_mod,
    :server_opts,
    :session_id_generator,
    :enable_json_response,
    :protocol_version,
    :sessions
  ]

  @doc """
  Creates a new Plug configuration.

  Returns a tuple `{MCP.Transport.StreamableHTTP.Plug, opts}` suitable
  for passing to Bandit or other HTTP servers.
  """
  def new(opts) do
    {__MODULE__, opts}
  end

  # --- Plug callbacks ---

  @impl Plug
  def init(%__MODULE__{} = config), do: config

  def init(opts) do
    server_mod = Keyword.fetch!(opts, :server_mod)
    server_opts = Keyword.get(opts, :server_opts, [])

    session_id_generator =
      case Keyword.get(opts, :session_id_generator, :default) do
        :default -> fn -> UUID.uuid4() end
        nil -> nil
        fun when is_function(fun, 0) -> fun
      end

    enable_json_response = Keyword.get(opts, :enable_json_response, false)
    protocol_version = Keyword.get(opts, :protocol_version, @protocol_version)

    # Create an ETS table to store session mappings
    sessions = :ets.new(:mcp_sessions, [:set, :public])

    %__MODULE__{
      server_mod: server_mod,
      server_opts: server_opts,
      session_id_generator: session_id_generator,
      enable_json_response: enable_json_response,
      protocol_version: protocol_version,
      sessions: sessions
    }
  end

  @impl Plug
  def call(conn, config) do
    if localhost_request?(conn) do
      route_method(conn, config)
    else
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(403, "Forbidden: non-localhost origin")
    end
  end

  defp route_method(conn, config) do
    case conn.method do
      "POST" -> handle_post(conn, config)
      "GET" -> handle_get(conn, config)
      "DELETE" -> handle_delete(conn, config)
      _ -> method_not_allowed(conn)
    end
  end

  # --- POST handler ---

  defp handle_post(conn, config) do
    with {:ok, body, conn} <- Plug.Conn.read_body(conn),
         {:ok, message} <- Jason.decode(body) do
      route_post(conn, config, message)
    else
      {:error, reason} ->
        send_json_error(conn, 400, -32_700, "Parse error", inspect(reason))
    end
  end

  defp route_post(conn, config, message) do
    cond do
      Map.get(message, "method") == "initialize" ->
        handle_initialize(conn, config, message)

      config.session_id_generator == nil ->
        handle_stateless_request(conn, config, message)

      true ->
        handle_session_request(conn, config, message)
    end
  end

  defp handle_initialize(conn, config, message) do
    session_id = generate_session_id(config)

    case create_session_and_deliver(config, session_id, message) do
      {:ok, response} ->
        conn
        |> maybe_set_session_header(session_id)
        |> send_response(config, response)

      :accepted ->
        Plug.Conn.send_resp(conn, 202, "")

      {:error, reason} ->
        send_json_error(conn, 500, -32_603, "Internal error", inspect(reason))
    end
  end

  defp handle_session_request(conn, config, message) do
    with {:ok, session_id} <- require_session_id(conn),
         :ok <- validate_protocol_version(conn, config),
         {:ok, transport_pid} <- lookup_session(config, session_id) do
      deliver_and_respond(conn, config, transport_pid, message)
    else
      {:error, :missing_session_id} ->
        send_json_error(conn, 400, -32_600, "Bad request", "Missing MCP-Session-Id header")

      {:error, {:bad_version, version}} ->
        send_json_error(
          conn,
          400,
          -32_000,
          "Unsupported protocol version",
          "Unsupported protocol version: #{version}"
        )

      :not_found ->
        send_json_error(conn, 404, -32_600, "Not found", "Session not found")
    end
  end

  defp handle_stateless_request(conn, config, message) do
    case :ets.first(config.sessions) do
      :"$end_of_table" ->
        send_json_error(conn, 400, -32_600, "Bad request", "Not initialized")

      session_id ->
        case lookup_session(config, session_id) do
          {:ok, transport_pid} -> deliver_and_respond(conn, config, transport_pid, message)
          :not_found -> send_json_error(conn, 400, -32_600, "Bad request", "Session expired")
        end
    end
  end

  defp deliver_and_respond(conn, config, transport_pid, message) do
    case HTTPTransport.deliver_message(transport_pid, message) do
      {:ok, response} -> send_response(conn, config, response)
      :accepted -> Plug.Conn.send_resp(conn, 202, "")
      {:error, reason} -> send_json_error(conn, 500, -32_603, "Internal error", inspect(reason))
    end
  end

  # --- GET handler ---

  defp handle_get(conn, config) do
    with :ok <- require_sse_accept(conn),
         {:ok, session_id} <- require_session_id_if_stateful(conn, config),
         {:ok, _transport_pid} <- lookup_session(config, session_id) do
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.send_resp(200, "")
    else
      {:error, :not_acceptable} ->
        send_json_error(conn, 406, -32_000, "Not Acceptable", "Must accept text/event-stream")

      {:error, :missing_session_id} ->
        send_json_error(conn, 400, -32_600, "Bad request", "Missing MCP-Session-Id header")

      :not_found ->
        send_json_error(conn, 404, -32_600, "Not found", "Session not found")
    end
  end

  # --- DELETE handler ---

  defp handle_delete(conn, config) do
    with {:ok, session_id} <- require_session_id(conn),
         {:ok, transport_pid} <- lookup_session(config, session_id) do
      HTTPTransport.close(transport_pid)
      :ets.delete(config.sessions, session_id)
      Plug.Conn.send_resp(conn, 200, "")
    else
      {:error, :missing_session_id} ->
        send_json_error(conn, 400, -32_600, "Bad request", "Missing MCP-Session-Id header")

      :not_found ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  # --- Helpers ---

  defp generate_session_id(config) do
    if config.session_id_generator do
      config.session_id_generator.()
    else
      nil
    end
  end

  defp create_session_and_deliver(config, session_id, message) do
    case start_session(config, session_id) do
      {:ok, transport_pid} ->
        if session_id, do: :ets.insert(config.sessions, {session_id, transport_pid})
        HTTPTransport.deliver_message(transport_pid, message)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_session(config, session_id) do
    transport_opts = [owner: self(), session_id: session_id]

    case HTTPTransport.start_link(transport_opts) do
      {:ok, transport_pid} ->
        case start_mcp_server(config, transport_pid) do
          {:ok, _server_pid} ->
            {:ok, transport_pid}

          {:error, reason} ->
            HTTPTransport.close(transport_pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_mcp_server(config, transport_pid) do
    server_opts = [
      handler: {config.server_mod, []},
      transport: {MCP.Transport.StreamableHTTP.PreStarted, pid: transport_pid}
    ]

    server_opts =
      server_opts ++
        Keyword.take(config.server_opts, [:server_info, :capabilities, :instructions])

    MCP.Server.start_link(server_opts)
  end

  defp require_session_id(conn) do
    case Plug.Conn.get_req_header(conn, "mcp-session-id") do
      [session_id | _] -> {:ok, session_id}
      [] -> {:error, :missing_session_id}
    end
  end

  defp require_session_id_if_stateful(conn, config) do
    if config.session_id_generator == nil do
      {:ok, :ets.first(config.sessions)}
    else
      require_session_id(conn)
    end
  end

  defp require_sse_accept(conn) do
    accept = Plug.Conn.get_req_header(conn, "accept")
    accepts_sse = Enum.any?(accept, &String.contains?(&1, "text/event-stream"))

    if accepts_sse do
      :ok
    else
      {:error, :not_acceptable}
    end
  end

  defp validate_protocol_version(conn, config) do
    case Plug.Conn.get_req_header(conn, "mcp-protocol-version") do
      [] -> :ok
      [version | _] when version == config.protocol_version -> :ok
      [version | _] -> {:error, {:bad_version, version}}
    end
  end

  defp lookup_session(config, session_id) do
    case :ets.lookup(config.sessions, session_id) do
      [{^session_id, pid}] ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          :ets.delete(config.sessions, session_id)
          :not_found
        end

      [] ->
        :not_found
    end
  end

  defp maybe_set_session_header(conn, nil), do: conn

  defp maybe_set_session_header(conn, session_id) do
    Plug.Conn.put_resp_header(conn, "mcp-session-id", session_id)
  end

  defp send_response(conn, config, response) do
    if config.enable_json_response do
      send_json_response(conn, response)
    else
      send_sse_response(conn, response)
    end
  end

  defp send_json_response(conn, response) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(response))
  end

  defp send_sse_response(conn, response) do
    sse_data = SSE.encode_message(response)

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.send_resp(200, sse_data)
  end

  defp send_json_error(conn, http_status, code, message, data) do
    error = %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => code, "message" => message, "data" => data}
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(http_status, Jason.encode!(error))
  end

  defp method_not_allowed(conn) do
    conn
    |> Plug.Conn.put_resp_header("allow", "GET, POST, DELETE")
    |> Plug.Conn.send_resp(405, "")
  end

  @localhost_patterns ~w(localhost 127.0.0.1 [::1])

  defp localhost_request?(conn) do
    origin = Plug.Conn.get_req_header(conn, "origin")
    host = Plug.Conn.get_req_header(conn, "host")

    origin_ok = origin == [] || Enum.any?(origin, &localhost_value?/1)
    host_ok = host == [] || Enum.any?(host, &localhost_value?/1)

    origin_ok && host_ok
  end

  defp localhost_value?(value) do
    # Strip scheme prefix if present
    host_part =
      value
      |> String.replace(~r{^https?://}, "")
      |> String.split("/")
      |> hd()

    # Strip port suffix
    host_without_port = String.replace(host_part, ~r{:\d+$}, "")

    host_without_port in @localhost_patterns
  end
end
