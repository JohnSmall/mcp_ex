defmodule MCP.Protocol.Messages.Tools do
  @moduledoc """
  Message types for `tools/list` and `tools/call`.
  """

  defmodule ListParams do
    @moduledoc """
    Parameters for `tools/list`.
    """

    @derive Jason.Encoder
    defstruct [:cursor, :meta]

    @type t :: %__MODULE__{
            cursor: String.t() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        cursor: Map.get(map, "cursor"),
        meta: Map.get(map, "_meta")
      }
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = params) do
      %{}
      |> maybe_put("cursor", params.cursor)
      |> maybe_put("_meta", params.meta)
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, val), do: Map.put(map, key, val)
  end

  defmodule ListResult do
    @moduledoc """
    Result of `tools/list`.
    """

    alias MCP.Protocol.Types.Tool

    @derive Jason.Encoder
    defstruct [:tools, :next_cursor, :meta]

    @type t :: %__MODULE__{
            tools: [Tool.t()],
            next_cursor: String.t() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        tools: map |> Map.fetch!("tools") |> Enum.map(&Tool.from_map/1),
        next_cursor: Map.get(map, "nextCursor"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{tools: struct.tools}

        map = if struct.next_cursor, do: Map.put(map, :nextCursor, struct.next_cursor), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map

        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule CallParams do
    @moduledoc """
    Parameters for `tools/call`.
    """

    @derive Jason.Encoder
    defstruct [:name, :arguments, :meta]

    @type t :: %__MODULE__{
            name: String.t(),
            arguments: map() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        name: Map.fetch!(map, "name"),
        arguments: Map.get(map, "arguments"),
        meta: Map.get(map, "_meta")
      }
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = params) do
      %{"name" => params.name}
      |> maybe_put("arguments", params.arguments)
      |> maybe_put("_meta", params.meta)
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, val), do: Map.put(map, key, val)
  end

  defmodule CallResult do
    @moduledoc """
    Result of `tools/call`.
    """

    alias MCP.Protocol.Types.Content

    @derive Jason.Encoder
    defstruct [:content, :structured_content, :is_error, :meta]

    @type t :: %__MODULE__{
            content: [Content.content_block()],
            structured_content: map() | nil,
            is_error: boolean() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        content: map |> Map.fetch!("content") |> Enum.map(&Content.from_map/1),
        structured_content: Map.get(map, "structuredContent"),
        is_error: Map.get(map, "isError"),
        meta: Map.get(map, "_meta")
      }
    end

    defimpl Jason.Encoder, for: __MODULE__ do
      def encode(struct, opts) do
        map = %{content: struct.content}

        map =
          if struct.structured_content,
            do: Map.put(map, :structuredContent, struct.structured_content),
            else: map

        map = if struct.is_error, do: Map.put(map, :isError, struct.is_error), else: map
        map = if struct.meta, do: Map.put(map, :_meta, struct.meta), else: map

        Jason.Encode.map(map, opts)
      end
    end
  end
end
