defmodule MCP.Protocol.Capabilities.SamplingCapabilities do
  @moduledoc """
  Client capability for sampling. Empty struct indicates support.
  """

  @derive Jason.Encoder
  defstruct []

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: t()
  def from_map(_map), do: %__MODULE__{}
end
