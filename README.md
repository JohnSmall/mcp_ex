# MCP Ex

Elixir implementation of the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) — an open protocol for integrating LLM applications with external data sources and tools.

Provides both **client** and **server** implementations with pluggable transports (stdio, Streamable HTTP).

**100% conformance** with the official MCP test suite (Tier 1).

## Features

- **MCP Client** — connect to any MCP server, discover and call tools, read resources, use prompts
- **MCP Server** — expose tools, resources, and prompts to MCP clients via a Handler behaviour
- **Transports** — stdio (subprocess) and Streamable HTTP (POST + SSE)
- **Full protocol support** — initialization handshake, capability negotiation, notifications, pagination
- **Async tool execution** — tools can send log messages, progress updates, and make bidirectional requests (sampling, elicitation) during execution
- **Conformance tested** — 30/30 scenarios, 40/40 checks against the official MCP conformance suite

## Protocol Version

Implements MCP specification **2025-11-25**.

## Installation

Add `mcp_ex` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mcp_ex, "~> 0.2"}
  ]
end
```

For **Streamable HTTP** transport support, also add these optional dependencies:

```elixir
def deps do
  [
    {:mcp_ex, "~> 0.2"},
    {:req, "~> 0.5"},        # HTTP client (for MCP client over HTTP)
    {:plug, "~> 1.16"},      # HTTP framework (for MCP server over HTTP)
    {:bandit, "~> 1.5"}      # HTTP server (for MCP server over HTTP)
  ]
end
```

The stdio transport works with zero additional dependencies.

## Client Examples

### Example 1: Connect to a stdio MCP server

Connect to an MCP server running as a subprocess. The client launches the server
process and communicates via stdin/stdout.

```elixir
# Start the client with a stdio transport
{:ok, client} = MCP.Client.start_link(
  transport: {MCP.Transport.Stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]},
  client_info: %{name: "my_app", version: "1.0.0"}
)

# Perform the initialization handshake
{:ok, info} = MCP.Client.connect(client)
IO.puts("Connected to #{info.server_info.name} #{info.server_info.version}")

# List available tools
{:ok, result} = MCP.Client.list_tools(client)
for tool <- result["tools"] do
  IO.puts("  Tool: #{tool["name"]} — #{tool["description"]}")
end

# Call a tool
{:ok, result} = MCP.Client.call_tool(client, "read_file", %{"path" => "/tmp/hello.txt"})
IO.puts("Result: #{hd(result["content"])["text"]}")

# List and read resources
{:ok, result} = MCP.Client.list_resources(client)
for resource <- result["resources"] do
  {:ok, data} = MCP.Client.read_resource(client, resource["uri"])
  IO.puts("#{resource["name"]}: #{hd(data["contents"])["text"]}")
end

# Clean up
MCP.Client.close(client)
```

### Example 2: Connect to a Streamable HTTP MCP server

Connect to an MCP server over HTTP with support for server-initiated
requests (sampling, elicitation).

```elixir
# Start the client with an HTTP transport
{:ok, client} = MCP.Client.start_link(
  transport: {MCP.Transport.StreamableHTTP.Client, url: "http://localhost:8080/mcp"},
  client_info: %{name: "my_app", version: "1.0.0"},
  # Handle server-initiated LLM sampling requests
  on_sampling: fn params ->
    # Forward to your LLM and return the result
    {:ok, %{
      "role" => "assistant",
      "content" => %{"type" => "text", "text" => "Sample response"},
      "model" => "my-model",
      "stopReason" => "endTurn"
    }}
  end,
  # Report filesystem roots to the server
  on_roots_list: fn _params ->
    {:ok, %{"roots" => [
      %{"uri" => "file:///home/user/project", "name" => "Project"}
    ]}}
  end,
  # Receive server notifications
  notification_handler: fn method, params ->
    IO.puts("Notification: #{method} #{inspect(params)}")
  end
)

# Connect and use the server
{:ok, _info} = MCP.Client.connect(client)

# Use pagination helpers to list all tools across pages
{:ok, all_tools} = MCP.Client.list_all_tools(client)
IO.puts("Found #{length(all_tools)} tools")

# Get a prompt template and use it
{:ok, result} = MCP.Client.get_prompt(client, "code_review", %{"language" => "elixir"})
IO.inspect(result["messages"])

MCP.Client.close(client)
```

## Server Examples

### Example 1: Stdio server with tools and resources

Define a handler module implementing the `MCP.Server.Handler` behaviour and
run it over stdio. The server auto-detects capabilities based on which
callbacks you implement.

```elixir
defmodule MyHandler do
  @behaviour MCP.Server.Handler

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_list_tools(_cursor, state) do
    tools = [
      %{
        "name" => "get_weather",
        "description" => "Get current weather for a city",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "city" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["city"]
        }
      },
      %{
        "name" => "calculate",
        "description" => "Evaluate a math expression",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "expression" => %{"type" => "string"}
          },
          "required" => ["expression"]
        }
      }
    ]

    {:ok, tools, nil, state}
  end

  @impl true
  def handle_call_tool("get_weather", %{"city" => city}, state) do
    # Your weather API logic here
    {:ok, [%{"type" => "text", "text" => "Weather in #{city}: 72F, sunny"}], state}
  end

  def handle_call_tool("calculate", %{"expression" => expr}, state) do
    case Code.eval_string(expr) do
      {result, _} ->
        {:ok, [%{"type" => "text", "text" => "#{result}"}], state}
    end
  rescue
    _ -> {:error, -32_602, "Invalid expression", state}
  end

  @impl true
  def handle_list_resources(_cursor, state) do
    resources = [
      %{"uri" => "config://app", "name" => "App Config", "mimeType" => "application/json"}
    ]

    {:ok, resources, nil, state}
  end

  @impl true
  def handle_read_resource("config://app", state) do
    config = Jason.encode!(%{debug: false, version: "1.0.0"})
    {:ok, [%{"uri" => "config://app", "text" => config}], state}
  end

  def handle_read_resource(uri, state) do
    {:error, -32_002, "Resource not found: #{uri}", state}
  end
end

# Run as a stdio server (for use as a subprocess)
{:ok, _server} = MCP.Server.start_link(
  transport: {MCP.Transport.Stdio, mode: :server},
  handler: {MyHandler, []},
  server_info: %{name: "my-server", version: "1.0.0"}
)
```

### Example 2: HTTP server with async tools

Serve over Streamable HTTP using Plug + Bandit. This example demonstrates
async tool execution with `handle_call_tool/4`, which receives a
`ToolContext` for sending log messages, progress updates, and making
server-to-client requests during tool execution.

```elixir
defmodule MyAsyncHandler do
  @behaviour MCP.Server.Handler

  alias MCP.Server.ToolContext

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_list_tools(_cursor, state) do
    tools = [
      %{
        "name" => "analyze_code",
        "description" => "Analyze code with LLM assistance",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "code" => %{"type" => "string"},
            "language" => %{"type" => "string"}
          },
          "required" => ["code"]
        }
      }
    ]

    {:ok, tools, nil, state}
  end

  # 4-arity handle_call_tool enables async execution with ToolContext
  @impl true
  def handle_call_tool("analyze_code", args, ctx, state) do
    code = args["code"]
    language = args["language"] || "unknown"

    # Send log messages to the client during execution
    ToolContext.log(ctx, "info", "Starting analysis of #{language} code")

    # Report progress
    ToolContext.send_progress(ctx, 0, 100)

    # Request LLM sampling from the client.
    # The server's request_timeout (default 30s) ensures this returns
    # even if the client can't respond (see "Sampling over HTTP" note below).
    sampling_result = ToolContext.request_sampling(ctx, %{
      "messages" => [
        %{
          "role" => "user",
          "content" => %{
            "type" => "text",
            "text" => "Analyze this #{language} code:\n\n#{code}"
          }
        }
      ],
      "maxTokens" => 1000
    })

    ToolContext.send_progress(ctx, 100, 100)
    ToolContext.log(ctx, "info", "Analysis complete")

    analysis =
      case sampling_result do
        {:ok, result} ->
          result["content"]["text"]

        {:error, _reason} ->
          # Fallback when sampling is unavailable or times out
          "Static analysis: #{language} code, #{String.length(code)} characters"
      end

    {:ok, [%{"type" => "text", "text" => analysis}], state}
  end

  @impl true
  def handle_list_prompts(_cursor, state) do
    prompts = [
      %{
        "name" => "review",
        "description" => "Code review prompt",
        "arguments" => [
          %{"name" => "code", "description" => "Code to review", "required" => true}
        ]
      }
    ]

    {:ok, prompts, nil, state}
  end

  @impl true
  def handle_get_prompt("review", %{"code" => code}, state) do
    result = %{
      "description" => "Code review",
      "messages" => [
        %{
          "role" => "user",
          "content" => %{
            "type" => "text",
            "text" => "Please review this code:\n\n#{code}"
          }
        }
      ]
    }

    {:ok, result, state}
  end
end

# Start the HTTP server
plug_config = MCP.Transport.StreamableHTTP.Plug.init(
  server_mod: MyAsyncHandler,
  server_opts: [
    server_info: %{name: "my-http-server", version: "1.0.0"}
  ]
)

{:ok, _bandit} = Bandit.start_link(
  plug: {MCP.Transport.StreamableHTTP.Plug, plug_config},
  port: 8080,
  ip: {127, 0, 0, 1}
)

IO.puts("MCP server running at http://localhost:8080/mcp")
```

### Sampling over HTTP

When using `ToolContext.request_sampling/2` over the Streamable HTTP transport,
be aware that the client's `Req.post` is synchronous — it blocks until the
entire SSE response stream completes. This means the client cannot process or
respond to the server's sampling request while the `tools/call` POST is still
in flight, so the sampling request will always time out.

The server's `request_timeout` option (default: 30 seconds) acts as a safety
net: after the timeout, `request_sampling` returns `{:error, :timeout}` and the
tool handler can continue with a fallback. Always handle the error case in your
tool handler as shown in the example above.

With the **stdio transport**, sampling works bidirectionally since messages flow
independently on stdin/stdout — the client can respond to the sampling request
while still waiting for the tool result.

## Handler Behaviour Reference

The `MCP.Server.Handler` behaviour has one required callback (`init/1`) and
optional callbacks for each MCP feature. The server automatically advertises
capabilities based on which callbacks your handler implements.

| Callback | MCP Feature | Capability |
|----------|-------------|------------|
| `handle_list_tools/2` | `tools/list` | tools |
| `handle_call_tool/3` | `tools/call` | tools (sync) |
| `handle_call_tool/4` | `tools/call` | tools (async, with ToolContext) |
| `handle_list_resources/2` | `resources/list` | resources |
| `handle_read_resource/2` | `resources/read` | resources |
| `handle_subscribe/2` | `resources/subscribe` | resources.subscribe |
| `handle_unsubscribe/2` | `resources/unsubscribe` | resources.subscribe |
| `handle_list_resource_templates/2` | `resources/templates/list` | resources |
| `handle_list_prompts/2` | `prompts/list` | prompts |
| `handle_get_prompt/3` | `prompts/get` | prompts |
| `handle_complete/3` | `completion/complete` | completions |
| `handle_set_log_level/2` | `logging/setLevel` | logging |

## Examples

See [mcp_ex_examples](https://github.com/JohnSmall/mcp_ex_examples) for complete, runnable example projects:

| Example | Transport | Description |
|---------|-----------|-------------|
| server_example_1 | Stdio | Weather/calculator server with sync tools and resources |
| server_example_2 | HTTP | Knowledge base server with async tools, prompts, resource templates, and logging |
| client_example_1 | Both | Basic client connecting to both servers |
| client_example_2 | Both | Advanced client with sampling callbacks, pagination, and notification handling |

## Documentation

- [MCP Specification (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25)
- [Architecture](docs/architecture.md) — module map, data flow, transport design
- [Implementation Plan](docs/implementation-plan.md) — phased build plan with task details
- [Onboarding](docs/onboarding.md) — full context for contributors

## License

MIT
