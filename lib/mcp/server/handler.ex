defmodule MCP.Server.Handler do
  @moduledoc """
  Behaviour for implementing MCP server feature handlers.

  Implement this behaviour to define how your server responds to client
  requests for tools, resources, prompts, completions, and logging.

  All callbacks are optional — the server only advertises capabilities
  for callbacks that your module actually implements.

  ## Example

      defmodule MyHandler do
        @behaviour MCP.Server.Handler

        @impl true
        def init(opts) do
          {:ok, %{tools: Keyword.get(opts, :tools, [])}}
        end

        @impl true
        def handle_list_tools(_cursor, state) do
          {:ok, state.tools, nil, state}
        end

        @impl true
        def handle_call_tool("echo", %{"message" => msg}, state) do
          {:ok, [%{"type" => "text", "text" => msg}], state}
        end
      end
  """

  @type state :: term()
  @type cursor :: String.t() | nil

  # --- Required callback ---

  @doc """
  Initialize handler state. Called when the server starts.
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  # --- Optional callbacks ---

  @doc """
  Return a list of tools. Called on `tools/list`.
  """
  @callback handle_list_tools(cursor(), state()) ::
              {:ok, tools :: [map()], next_cursor :: cursor(), state()}

  @doc """
  Execute a tool. Called on `tools/call`.
  """
  @callback handle_call_tool(name :: String.t(), arguments :: map(), state()) ::
              {:ok, content :: [map()], state()}
              | {:ok, content :: [map()], is_error :: boolean(), state()}
              | {:error, code :: integer(), message :: String.t(), state()}

  @doc """
  Execute a tool with context. Called on `tools/call` when the handler
  implements this 4-arity version.

  The context (`MCP.Server.ToolContext`) allows sending notifications
  (logging, progress) and making server-to-client requests (sampling,
  elicitation) during tool execution.

  When this callback is implemented, tool execution runs asynchronously,
  enabling SSE streaming of intermediate messages.
  """
  @callback handle_call_tool(
              name :: String.t(),
              arguments :: map(),
              context :: MCP.Server.ToolContext.t(),
              state()
            ) ::
              {:ok, content :: [map()], state()}
              | {:ok, content :: [map()], is_error :: boolean(), state()}
              | {:error, code :: integer(), message :: String.t(), state()}

  @doc """
  Return a list of resources. Called on `resources/list`.
  """
  @callback handle_list_resources(cursor(), state()) ::
              {:ok, resources :: [map()], next_cursor :: cursor(), state()}

  @doc """
  Read a resource by URI. Called on `resources/read`.
  """
  @callback handle_read_resource(uri :: String.t(), state()) ::
              {:ok, contents :: [map()], state()}
              | {:error, code :: integer(), message :: String.t(), state()}

  @doc """
  Subscribe to resource updates. Called on `resources/subscribe`.
  """
  @callback handle_subscribe(uri :: String.t(), state()) ::
              {:ok, state()} | {:error, code :: integer(), message :: String.t(), state()}

  @doc """
  Unsubscribe from resource updates. Called on `resources/unsubscribe`.
  """
  @callback handle_unsubscribe(uri :: String.t(), state()) ::
              {:ok, state()} | {:error, code :: integer(), message :: String.t(), state()}

  @doc """
  Return a list of resource templates. Called on `resources/templates/list`.
  """
  @callback handle_list_resource_templates(cursor(), state()) ::
              {:ok, templates :: [map()], next_cursor :: cursor(), state()}

  @doc """
  Return a list of prompts. Called on `prompts/list`.
  """
  @callback handle_list_prompts(cursor(), state()) ::
              {:ok, prompts :: [map()], next_cursor :: cursor(), state()}

  @doc """
  Get a specific prompt. Called on `prompts/get`.
  """
  @callback handle_get_prompt(name :: String.t(), arguments :: map() | nil, state()) ::
              {:ok, result :: map(), state()}
              | {:error, code :: integer(), message :: String.t(), state()}

  @doc """
  Complete an argument value. Called on `completion/complete`.
  """
  @callback handle_complete(ref :: map(), argument :: map(), state()) ::
              {:ok, completion :: map(), state()}

  @doc """
  Set the logging level. Called on `logging/setLevel`.
  """
  @callback handle_set_log_level(level :: String.t(), state()) :: {:ok, state()}

  @optional_callbacks [
    handle_list_tools: 2,
    handle_call_tool: 3,
    handle_call_tool: 4,
    handle_list_resources: 2,
    handle_read_resource: 2,
    handle_subscribe: 2,
    handle_unsubscribe: 2,
    handle_list_resource_templates: 2,
    handle_list_prompts: 2,
    handle_get_prompt: 3,
    handle_complete: 3,
    handle_set_log_level: 2
  ]
end
