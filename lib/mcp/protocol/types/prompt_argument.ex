defmodule MCP.Protocol.Types.PromptArgument do
  @moduledoc """
  An argument for an MCP prompt template.
  """

  @derive Jason.Encoder
  defstruct [:name, :title, :description, :required]

  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          required: boolean() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: Map.fetch!(map, "name"),
      title: Map.get(map, "title"),
      description: Map.get(map, "description"),
      required: Map.get(map, "required")
    }
  end
end
