defmodule MCP.Protocol.Error do
  @moduledoc """
  MCP protocol error codes and error struct.

  Covers standard JSON-RPC 2.0 error codes and MCP-specific error codes.
  """

  @derive Jason.Encoder
  defstruct [:code, :message, :data]

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: term()
        }

  # Standard JSON-RPC 2.0 error codes
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  # MCP-specific error codes
  @resource_not_found -32_002
  @url_elicitation_required -32_042

  def parse_error_code, do: @parse_error
  def invalid_request_code, do: @invalid_request
  def method_not_found_code, do: @method_not_found
  def invalid_params_code, do: @invalid_params
  def internal_error_code, do: @internal_error
  def resource_not_found_code, do: @resource_not_found
  def url_elicitation_required_code, do: @url_elicitation_required

  @spec parse_error(term()) :: t()
  def parse_error(data \\ nil) do
    %__MODULE__{code: @parse_error, message: "Parse error", data: data}
  end

  @spec invalid_request(term()) :: t()
  def invalid_request(data \\ nil) do
    %__MODULE__{code: @invalid_request, message: "Invalid request", data: data}
  end

  @spec method_not_found(String.t() | nil) :: t()
  def method_not_found(method \\ nil) do
    %__MODULE__{code: @method_not_found, message: "Method not found", data: method}
  end

  @spec invalid_params(term()) :: t()
  def invalid_params(data \\ nil) do
    %__MODULE__{code: @invalid_params, message: "Invalid params", data: data}
  end

  @spec internal_error(term()) :: t()
  def internal_error(data \\ nil) do
    %__MODULE__{code: @internal_error, message: "Internal error", data: data}
  end

  @spec resource_not_found(String.t() | nil) :: t()
  def resource_not_found(uri \\ nil) do
    %__MODULE__{code: @resource_not_found, message: "Resource not found", data: uri}
  end

  @spec url_elicitation_required(map() | nil) :: t()
  def url_elicitation_required(data \\ nil) do
    %__MODULE__{code: @url_elicitation_required, message: "URL elicitation required", data: data}
  end

  @doc """
  Converts a wire-format map to an Error struct.
  """
  @spec from_map(map()) :: t()
  def from_map(%{"code" => code, "message" => message} = map) do
    %__MODULE__{
      code: code,
      message: message,
      data: Map.get(map, "data")
    }
  end
end
