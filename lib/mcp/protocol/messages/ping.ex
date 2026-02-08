defmodule MCP.Protocol.Messages.Ping do
  @moduledoc """
  Message types for the `ping` method.
  """

  defmodule Params do
    @moduledoc """
    Parameters for the `ping` request (empty).
    """

    @derive Jason.Encoder
    defstruct [:meta]

    @type t :: %__MODULE__{meta: map() | nil}

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{meta: Map.get(map, "_meta")}
    end
  end
end
