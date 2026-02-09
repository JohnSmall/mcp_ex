defmodule MCP.Transport.StreamableHTTP.PreStarted do
  @moduledoc """
  A transport adapter that wraps an already-started transport process.

  Used by `MCP.Transport.StreamableHTTP.Plug` to pass an existing
  transport GenServer to `MCP.Server.start_link/1`. The MCP.Server
  calls `start_link/1` during init, but we need to reuse an already
  running transport. This adapter simply re-registers the owner on
  the existing transport.

  ## Options

    * `:owner` — the new owner pid (set by MCP.Server during init)
    * `:pid` — the existing transport process pid
  """

  @behaviour MCP.Transport

  alias MCP.Transport.StreamableHTTP.Server, as: HTTPTransport

  @impl MCP.Transport
  def start_link(opts) do
    pid = Keyword.fetch!(opts, :pid)
    owner = Keyword.fetch!(opts, :owner)

    # Update the transport's owner to the MCP.Server
    GenServer.call(pid, {:set_owner, owner})

    # Return the existing pid as if we just started it
    {:ok, pid}
  end

  @impl MCP.Transport
  def send_message(pid, message) do
    HTTPTransport.send_message(pid, message)
  end

  @doc """
  Sends a message with options, delegating to the underlying transport.
  """
  def send_message(pid, message, opts) do
    HTTPTransport.send_message(pid, message, opts)
  end

  @impl MCP.Transport
  def close(pid) do
    HTTPTransport.close(pid)
  end
end
