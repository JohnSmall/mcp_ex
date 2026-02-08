defmodule MCP.Protocol.Messages.Initialize do
  @moduledoc """
  Message types for the MCP initialize handshake.
  """

  defmodule Params do
    @moduledoc """
    Parameters for the `initialize` request.
    """

    alias MCP.Protocol.Capabilities.ClientCapabilities
    alias MCP.Protocol.Types.Implementation

    @derive Jason.Encoder
    defstruct [:protocol_version, :capabilities, :client_info, :meta]

    @type t :: %__MODULE__{
            protocol_version: String.t(),
            capabilities: ClientCapabilities.t(),
            client_info: Implementation.t(),
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        protocol_version: Map.fetch!(map, "protocolVersion"),
        capabilities: map |> Map.fetch!("capabilities") |> ClientCapabilities.from_map(),
        client_info: map |> Map.fetch!("clientInfo") |> Implementation.from_map(),
        meta: Map.get(map, "_meta")
      }
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = params) do
      map = %{
        "protocolVersion" => params.protocol_version,
        "capabilities" => Jason.decode!(Jason.encode!(params.capabilities)),
        "clientInfo" => Jason.decode!(Jason.encode!(params.client_info))
      }

      case params.meta do
        nil -> map
        meta -> Map.put(map, "_meta", meta)
      end
    end
  end

  defmodule Result do
    @moduledoc """
    Result of the `initialize` request.
    """

    alias MCP.Protocol.Capabilities.ServerCapabilities
    alias MCP.Protocol.Types.Implementation

    @derive Jason.Encoder
    defstruct [:protocol_version, :capabilities, :server_info, :instructions, :meta]

    @type t :: %__MODULE__{
            protocol_version: String.t(),
            capabilities: ServerCapabilities.t(),
            server_info: Implementation.t(),
            instructions: String.t() | nil,
            meta: map() | nil
          }

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        protocol_version: Map.fetch!(map, "protocolVersion"),
        capabilities: map |> Map.fetch!("capabilities") |> ServerCapabilities.from_map(),
        server_info: map |> Map.fetch!("serverInfo") |> Implementation.from_map(),
        instructions: Map.get(map, "instructions"),
        meta: Map.get(map, "_meta")
      }
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = result) do
      map = %{
        "protocolVersion" => result.protocol_version,
        "capabilities" => Jason.decode!(Jason.encode!(result.capabilities)),
        "serverInfo" => Jason.decode!(Jason.encode!(result.server_info))
      }

      map =
        if result.instructions, do: Map.put(map, "instructions", result.instructions), else: map

      if result.meta, do: Map.put(map, "_meta", result.meta), else: map
    end
  end
end
