defmodule MCP.Protocol.Types.Tool do
  @moduledoc """
  An MCP tool definition.

  Tools are functions that can be called by an LLM via the MCP client.
  """

  alias MCP.Protocol.Types.{Icon, ToolAnnotations}

  @derive Jason.Encoder
  defstruct [
    :name,
    :title,
    :description,
    :input_schema,
    :output_schema,
    :annotations,
    :icons,
    :meta
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          input_schema: map(),
          output_schema: map() | nil,
          annotations: ToolAnnotations.t() | nil,
          icons: [Icon.t()] | nil,
          meta: map() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: Map.fetch!(map, "name"),
      title: Map.get(map, "title"),
      description: Map.get(map, "description"),
      input_schema: Map.fetch!(map, "inputSchema"),
      output_schema: Map.get(map, "outputSchema"),
      annotations: map |> Map.get("annotations") |> parse_annotations(),
      icons: map |> Map.get("icons") |> parse_icons(),
      meta: Map.get(map, "_meta")
    }
  end

  defp parse_annotations(nil), do: nil
  defp parse_annotations(map), do: ToolAnnotations.from_map(map)

  defp parse_icons(nil), do: nil
  defp parse_icons(icons), do: Enum.map(icons, &Icon.from_map/1)

  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(struct, opts) do
      struct
      |> Map.from_struct()
      |> Enum.reduce(%{}, fn
        {_key, nil}, acc -> acc
        {:input_schema, val}, acc -> Map.put(acc, :inputSchema, val)
        {:output_schema, val}, acc -> Map.put(acc, :outputSchema, val)
        {:meta, val}, acc -> Map.put(acc, :_meta, val)
        {key, val}, acc -> Map.put(acc, key, val)
      end)
      |> Jason.Encode.map(opts)
    end
  end
end
