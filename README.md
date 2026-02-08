# MCP Ex

Elixir implementation of the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) — an open protocol for integrating LLM applications with external data sources and tools.

Provides both **client** and **server** implementations with pluggable transports.

## Features

- MCP Client — connect to MCP servers, discover and call tools, read resources, use prompts
- MCP Server — expose tools, resources, and prompts to MCP clients
- Transports — stdio (subprocess) and Streamable HTTP (POST + SSE)
- Full protocol support — initialization, capability negotiation, notifications, pagination
- Sampling — server-initiated LLM requests via client
- Elicitation — server-initiated user input requests via client
- Conformance tested against the official MCP test suite

## Protocol Version

Implements MCP specification **2025-11-25**.

## Installation

Add `mcp_ex` to your dependencies:

```elixir
def deps do
  [
    {:mcp_ex, "~> 0.1"}
  ]
end
```

## Quick Example — Server

```elixir
# Define a tool
defmodule MyTools do
  def get_weather(args) do
    city = args["city"]
    {:ok, [%{type: "text", text: "Weather in #{city}: 72F, sunny"}]}
  end
end

# Start server
{:ok, server} = MCP.Server.new(
  name: "weather-server",
  version: "1.0.0",
  tools: [
    %{
      name: "get_weather",
      description: "Get current weather for a city",
      input_schema: %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      },
      handler: &MyTools.get_weather/1
    }
  ]
)

# Run over stdio
MCP.Server.run(server, transport: :stdio)
```

## Quick Example — Client

```elixir
# Connect to an MCP server
{:ok, client} = MCP.Client.connect("my-server",
  transport: {:stdio, command: "npx my-mcp-server"}
)

# Discover tools
{:ok, tools} = MCP.Client.list_tools(client)

# Call a tool
{:ok, result} = MCP.Client.call_tool(client, "get_weather", %{"city" => "Paris"})
```

## ADK Integration

Use with the [Elixir ADK](https://github.com/JohnSmall/adk_ex) via `ADK.Tool.McpToolset`:

```elixir
toolset = MCP.ADKToolset.new(transport: {:stdio, command: "npx my-server"})

agent = %ADK.Agent.LlmAgent{
  name: "my_agent",
  model: model,
  toolsets: [toolset]
}
```

## Documentation

- [MCP Specification](https://modelcontextprotocol.io/specification/2025-11-25)
- [SDK Tiers](https://modelcontextprotocol.io/community/sdk-tiers)
- [Conformance Tests](https://github.com/modelcontextprotocol/conformance)

## License

MIT
