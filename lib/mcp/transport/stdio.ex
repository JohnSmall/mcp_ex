defmodule MCP.Transport.Stdio do
  @moduledoc """
  Stdio transport for MCP.

  Communicates via newline-delimited JSON-RPC over stdin/stdout.

  ## Client mode

  Launches a subprocess via an Erlang Port. Messages are written as
  JSON + newline to the subprocess's stdin, and read as newline-delimited
  JSON from stdout. Stderr goes to the parent process's stderr.

  ## Server mode

  Reads from the process's own stdin and writes to stdout. Used when
  this Elixir process IS the MCP server subprocess.

  ## Options

    * `:owner` (required) — pid to receive `{:mcp_message, map}` and
      `{:mcp_transport_closed, reason}` messages
    * `:command` — path to executable (client mode). When provided, a
      subprocess is spawned.
    * `:args` — arguments for the command (default: `[]`)
    * `:env` — environment variables as `[{String.t(), String.t()}]`
    * `:mode` — `:client` (default when `:command` given) or `:server`
  """

  use GenServer

  require Logger

  @behaviour MCP.Transport

  defstruct [:owner, :mode, :port, :buffer, :io_device, :reader_pid]

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

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    mode = determine_mode(opts)

    state = %__MODULE__{
      owner: owner,
      mode: mode,
      buffer: ""
    }

    case mode do
      :client -> init_client(state, opts)
      :server -> init_server(state)
    end
  end

  @impl GenServer
  def handle_call({:send_message, message}, _from, state) do
    case do_send(state, message) do
      :ok -> {:reply, :ok, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:close, _from, state) do
    do_close(state)
    {:stop, :normal, :ok, state}
  end

  # Port messages (client mode)
  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_buffer = state.buffer <> data
    {messages, remaining} = extract_lines(new_buffer)

    Enum.each(messages, fn line ->
      case Jason.decode(line) do
        {:ok, decoded} ->
          send(state.owner, {:mcp_message, decoded})

        {:error, reason} ->
          Logger.warning("MCP Stdio: failed to decode JSON: #{inspect(reason)}")
      end
    end)

    {:noreply, %{state | buffer: remaining}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:mcp_transport_closed, {:exit_status, status}})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    send(state.owner, {:mcp_transport_closed, reason})
    {:stop, :normal, %{state | port: nil}}
  end

  # Server mode: stdin reader sends us lines
  def handle_info({:stdio_line, line}, state) do
    case Jason.decode(line) do
      {:ok, decoded} ->
        send(state.owner, {:mcp_message, decoded})

      {:error, reason} ->
        Logger.warning("MCP Stdio: failed to decode JSON from stdin: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(:stdio_eof, state) do
    send(state.owner, {:mcp_transport_closed, :eof})
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.debug("MCP Stdio: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    do_close(state)
    :ok
  end

  # --- Private helpers ---

  defp determine_mode(opts) do
    cond do
      Keyword.has_key?(opts, :command) -> :client
      Keyword.get(opts, :mode) == :server -> :server
      true -> :server
    end
  end

  defp init_client(state, opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])

    env_charlist = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, args},
      {:env, env_charlist}
    ]

    port = Port.open({:spawn_executable, String.to_charlist(command)}, port_opts)

    {:ok, %{state | port: port}}
  end

  defp init_server(state) do
    transport = self()

    pid =
      spawn_link(fn ->
        stdio_read_loop(transport)
      end)

    {:ok, %{state | reader_pid: pid}}
  end

  defp stdio_read_loop(transport) do
    case :io.get_line(:standard_io, ~c"") do
      :eof ->
        send(transport, :stdio_eof)

      {:error, _reason} ->
        send(transport, :stdio_eof)

      data when is_binary(data) ->
        line = String.trim_trailing(data, "\n")

        if line != "" do
          send(transport, {:stdio_line, line})
        end

        stdio_read_loop(transport)

      data when is_list(data) ->
        line = data |> IO.chardata_to_string() |> String.trim_trailing("\n")

        if line != "" do
          send(transport, {:stdio_line, line})
        end

        stdio_read_loop(transport)
    end
  end

  defp do_send(%{mode: :client, port: port}, message) when is_port(port) do
    json = Jason.encode!(message)
    Port.command(port, [json, "\n"])
    :ok
  rescue
    e -> {:error, e}
  end

  defp do_send(%{mode: :server}, message) do
    json = Jason.encode!(message)
    IO.write(:stdio, [json, "\n"])
    :ok
  rescue
    e -> {:error, e}
  end

  defp do_close(%{mode: :client, port: port}) when is_port(port) do
    Port.close(port)
    :ok
  catch
    _, _ -> :ok
  end

  defp do_close(%{mode: :server, reader_pid: pid}) when is_pid(pid) do
    Process.exit(pid, :shutdown)
  end

  defp do_close(_state), do: :ok

  defp extract_lines(buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [complete, rest] ->
        {more, remaining} = extract_lines(rest)
        {[complete | more], remaining}

      [incomplete] ->
        {[], incomplete}
    end
  end
end
