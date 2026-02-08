defmodule MCP.Protocol.Types.Content do
  @moduledoc """
  Polymorphic content types used in tool results, prompts, and resources.

  Content blocks are discriminated by their `type` field:
  - `"text"` — TextContent
  - `"image"` — ImageContent
  - `"audio"` — AudioContent
  - `"resource"` — EmbeddedResource
  - `"resource_link"` — ResourceLink
  """

  alias MCP.Protocol.Types.Content.{
    AudioContent,
    EmbeddedResource,
    ImageContent,
    ResourceLink,
    TextContent
  }

  @type content_block ::
          TextContent.t()
          | ImageContent.t()
          | AudioContent.t()
          | EmbeddedResource.t()
          | ResourceLink.t()

  @doc """
  Parses a wire-format map into the appropriate content struct.
  """
  @spec from_map(map()) :: content_block()
  def from_map(%{"type" => "text"} = map), do: TextContent.from_map(map)
  def from_map(%{"type" => "image"} = map), do: ImageContent.from_map(map)
  def from_map(%{"type" => "audio"} = map), do: AudioContent.from_map(map)
  def from_map(%{"type" => "resource"} = map), do: EmbeddedResource.from_map(map)
  def from_map(%{"type" => "resource_link"} = map), do: ResourceLink.from_map(map)
end
