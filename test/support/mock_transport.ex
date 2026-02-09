defmodule MCP.Test.MockTransport do
  @moduledoc """
  In-memory transport for unit testing MCP client/server.

  Collects sent messages and allows injecting incoming messages.
  """

  use GenServer

  @behaviour MCP.Transport

  defstruct [:owner, :sent, :closed]

  @impl MCP.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl MCP.Transport
  def send_message(pid, message) do
    GenServer.call(pid, {:send_message, message})
  end

  @impl MCP.Transport
  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Inject a message as if it came from the remote side.
  """
  def inject(pid, message) do
    GenServer.cast(pid, {:inject, message})
  end

  @doc """
  Returns all messages sent through this transport.
  """
  def sent_messages(pid) do
    GenServer.call(pid, :sent_messages)
  end

  @doc """
  Returns the last message sent through this transport, or nil.
  """
  def last_sent(pid) do
    GenServer.call(pid, :last_sent)
  end

  @doc """
  Returns whether close has been called.
  """
  def closed?(pid) do
    GenServer.call(pid, :closed?)
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    {:ok, %__MODULE__{owner: owner, sent: [], closed: false}}
  end

  @impl GenServer
  def handle_call({:send_message, message}, _from, state) do
    {:reply, :ok, %{state | sent: state.sent ++ [message]}}
  end

  def handle_call(:close, _from, state) do
    send(state.owner, {:mcp_transport_closed, :normal})
    {:reply, :ok, %{state | closed: true}}
  end

  def handle_call(:sent_messages, _from, state) do
    {:reply, state.sent, state}
  end

  def handle_call(:last_sent, _from, state) do
    {:reply, List.last(state.sent), state}
  end

  def handle_call(:closed?, _from, state) do
    {:reply, state.closed, state}
  end

  @impl GenServer
  def handle_cast({:inject, message}, state) do
    send(state.owner, {:mcp_message, message})
    {:noreply, state}
  end
end
