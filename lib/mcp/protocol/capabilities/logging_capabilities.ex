defmodule MCP.Protocol.Capabilities.LoggingCapabilities do
  @moduledoc """
  Server capability for logging. Empty struct indicates support.
  """

  @derive Jason.Encoder
  defstruct []

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: t()
  def from_map(_map), do: %__MODULE__{}
end
