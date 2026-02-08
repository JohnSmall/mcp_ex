defmodule MCP.Protocol.Types.PromptMessage do
  @moduledoc """
  A message within a prompt result.
  """

  alias MCP.Protocol.Types.Content

  @derive Jason.Encoder
  defstruct [:role, :content]

  @type t :: %__MODULE__{
          role: String.t(),
          content: Content.content_block()
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      role: Map.fetch!(map, "role"),
      content: map |> Map.fetch!("content") |> Content.from_map()
    }
  end
end
