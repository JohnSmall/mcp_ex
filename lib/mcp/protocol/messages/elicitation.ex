defmodule MCP.Protocol.Messages.Elicitation do
  @moduledoc """
  Message types for `elicitation/create`.
  """

  defmodule Params do
    @moduledoc """
    Parameters for `elicitation/create`.
    """

    @derive Jason.Encoder
    defstruct [:mode, :message, :requested_schema, :url, :elicitation_id, :meta]

    @type t :: %__MODULE__{
            mode: String.t() | nil,
            message: String.t(),
            requested_schema: map() | nil,
            url: String.t() | nil,
            elicitation_id: String.t() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        mode: Map.get(map, "mode"),
        message: Map.fetch!(map, "message"),
        requested_schema: Map.get(map, "requestedSchema"),
        url: Map.get(map, "url"),
        elicitation_id: Map.get(map, "elicitationId"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{message: struct.message}

        map =
          struct
          |> Map.from_struct()
          |> Enum.reduce(map, fn
            {:message, _}, acc -> acc
            {_key, nil}, acc -> acc
            {:requested_schema, val}, acc -> Map.put(acc, :requestedSchema, val)
            {:elicitation_id, val}, acc -> Map.put(acc, :elicitationId, val)
            {:meta, val}, acc -> Map.put(acc, :_meta, val)
            {key, val}, acc -> Map.put(acc, key, val)
          end)

        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule Result do
    @moduledoc """
    Result of `elicitation/create`.
    """

    @derive Jason.Encoder
    defstruct [:action, :content, :meta]

    @type t :: %__MODULE__{
            action: String.t(),
            content: map() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        action: Map.fetch!(map, "action"),
        content: Map.get(map, "content"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{action: struct.action}
        map = if struct.content, do: Map.put(map, :content, struct.content), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map
        Jason.Encode.map(map, opts)
      end
    end
  end
end
