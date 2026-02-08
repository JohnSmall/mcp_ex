defmodule MCP.Protocol.Types.ModelHint do
  @moduledoc """
  A hint for model selection in sampling requests.
  """

  @derive Jason.Encoder
  defstruct [:name]

  @type t :: %__MODULE__{
          name: String.t() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: Map.get(map, "name")
    }
  end
end
