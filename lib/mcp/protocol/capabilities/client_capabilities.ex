defmodule MCP.Protocol.Capabilities.ClientCapabilities do
  @moduledoc """
  Capabilities declared by an MCP client during initialization.
  """

  alias MCP.Protocol.Capabilities.{
    ElicitationCapabilities,
    RootCapabilities,
    SamplingCapabilities
  }

  @derive Jason.Encoder
  defstruct [:roots, :sampling, :elicitation, :experimental]

  @type t :: %__MODULE__{
          roots: RootCapabilities.t() | nil,
          sampling: SamplingCapabilities.t() | nil,
          elicitation: ElicitationCapabilities.t() | nil,
          experimental: map() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      roots: map |> Map.get("roots") |> parse_cap(RootCapabilities),
      sampling: map |> Map.get("sampling") |> parse_cap(SamplingCapabilities),
      elicitation: map |> Map.get("elicitation") |> parse_cap(ElicitationCapabilities),
      experimental: Map.get(map, "experimental")
    }
  end

  defp parse_cap(nil, _module), do: nil
  defp parse_cap(map, module), do: module.from_map(map)

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      struct
      |> Map.from_struct()
      |> Enum.reduce(%{}, fn
        {_key, nil}, acc -> acc
        {key, val}, acc -> Map.put(acc, key, val)
      end)
      |> Jason.Encode.map(opts)
    end
  end
end
