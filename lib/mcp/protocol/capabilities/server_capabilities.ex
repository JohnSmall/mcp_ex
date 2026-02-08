defmodule MCP.Protocol.Capabilities.ServerCapabilities do
  @moduledoc """
  Capabilities declared by an MCP server during initialization.
  """

  alias MCP.Protocol.Capabilities.{
    CompletionCapabilities,
    LoggingCapabilities,
    PromptCapabilities,
    ResourceCapabilities,
    ToolCapabilities
  }

  @derive Jason.Encoder
  defstruct [:tools, :resources, :prompts, :logging, :completions, :experimental]

  @type t :: %__MODULE__{
          tools: ToolCapabilities.t() | nil,
          resources: ResourceCapabilities.t() | nil,
          prompts: PromptCapabilities.t() | nil,
          logging: LoggingCapabilities.t() | nil,
          completions: CompletionCapabilities.t() | nil,
          experimental: map() | nil
        }

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      tools: map |> Map.get("tools") |> parse_cap(ToolCapabilities),
      resources: map |> Map.get("resources") |> parse_cap(ResourceCapabilities),
      prompts: map |> Map.get("prompts") |> parse_cap(PromptCapabilities),
      logging: map |> Map.get("logging") |> parse_cap(LoggingCapabilities),
      completions: map |> Map.get("completions") |> parse_cap(CompletionCapabilities),
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
