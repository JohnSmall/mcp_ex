defmodule MCP.Transport do
  @moduledoc """
  Behaviour for MCP transports.

  A transport handles the I/O layer for MCP communication — framing,
  sending, and receiving JSON-RPC messages over a specific channel
  (stdio, HTTP, etc.).

  Transports run as processes (typically GenServers) owned by a client or
  server. Incoming messages are delivered to the owner process via:

      send(owner, {:mcp_message, decoded_map})

  Transport closure is signaled via:

      send(owner, {:mcp_transport_closed, reason})
  """

  @type opts :: keyword()
  @type message :: map()

  @doc """
  Starts the transport process, linked to the caller.

  Options must include `:owner` — the pid that will receive incoming messages.
  """
  @callback start_link(opts()) :: GenServer.on_start()

  @doc """
  Sends a JSON-RPC message (as a map) through the transport.
  """
  @callback send_message(pid :: pid(), message()) :: :ok | {:error, term()}

  @doc """
  Closes the transport, releasing all resources.
  """
  @callback close(pid :: pid()) :: :ok
end
