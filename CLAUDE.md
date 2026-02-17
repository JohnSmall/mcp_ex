# MCP Ex - Claude CLI Instructions

## Project Overview

Elixir implementation of the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP). Standalone library providing both MCP **client** and **server** with pluggable transports. Protocol version: **2025-11-25**.

MCP is an open protocol that enables standardized integration between LLM applications and external data sources and tools. It uses JSON-RPC 2.0 over pluggable transports (stdio, Streamable HTTP).

**Related packages**:
- `adk_ex` at `/workspace/elixir_code/adk_ex/` — Elixir ADK (Agent Development Kit). Will use `mcp_ex` client via an `ADK.Tool.McpToolset` adapter.
- `adk_ex_ecto` at `/workspace/elixir_code/adk_ex_ecto/` — Ecto-backed sessions for ADK.

## Quick Start

```bash
cd /workspace/elixir_code/mcp_ex
mix deps.get
mix test
mix credo
mix dialyzer
```

## Key Documentation

- **PRD**: `docs/prd.md` — Requirements, protocol features, design decisions
- **Architecture**: `docs/architecture.md` — Module map, data flow, transport design
- **Implementation Plan**: `docs/implementation-plan.md` — Phased tasks with detailed breakdown
- **Onboarding**: `docs/onboarding.md` — Full context for new agents (patterns, gotchas)
- **MCP Spec**: https://modelcontextprotocol.io/specification/2025-11-25

## Reference Codebases (download locally for coding)

| SDK | Location | Notes |
|-----|----------|-------|
| **Go SDK (PRIMARY)** | `/workspace/samples/mcp-go-sdk/` | Official Go SDK, most complete, well-structured |
| **Python SDK** | `/workspace/samples/mcp-python-sdk/` | Official Python SDK, decorator-based API |
| **Ruby SDK** | `/workspace/samples/mcp-ruby-sdk/` | Official Ruby SDK (Shopify), good OOP patterns |
| **TypeScript SDK** | `/workspace/samples/mcp-typescript-sdk/` | Reference implementation |

**GitHub repos to clone:**
```bash
git clone https://github.com/modelcontextprotocol/go-sdk /workspace/samples/mcp-go-sdk
git clone https://github.com/modelcontextprotocol/python-sdk /workspace/samples/mcp-python-sdk
git clone https://github.com/modelcontextprotocol/ruby-sdk /workspace/samples/mcp-ruby-sdk
git clone https://github.com/modelcontextprotocol/typescript-sdk /workspace/samples/mcp-typescript-sdk
git clone https://github.com/modelcontextprotocol/conformance /workspace/samples/mcp-conformance
```

## Protocol Version

Target: **2025-11-25** (latest stable). The TypeScript schema is the source of truth:
https://github.com/modelcontextprotocol/specification/blob/main/schema/2025-11-25/schema.ts

## Module Map (Planned)

### Core Protocol
- `MCP.Protocol` — JSON-RPC 2.0 message types, framing, ID generation
- `MCP.Protocol.Types` — All MCP types (Tool, Resource, Prompt, Content, etc.)
- `MCP.Protocol.Messages` — Request/response/notification structs for all MCP methods
- `MCP.Protocol.Capabilities` — Client and server capability structs

### Transport Layer
- `MCP.Transport` — Transport behaviour (send, receive, close)
- `MCP.Transport.Stdio` — stdin/stdout transport (newline-delimited JSON-RPC)
- `MCP.Transport.StreamableHTTP` — HTTP POST + SSE transport with session management

### Client
- `MCP.Client` — High-level client API (connect, list_tools, call_tool, etc.)
- `MCP.Client.Session` — Manages single client-server connection lifecycle

### Server
- `MCP.Server` — High-level server API (register tools/resources/prompts, run)
- `MCP.Server.Handler` — Behaviour for implementing server feature handlers
- `MCP.Server.Router` — Routes incoming JSON-RPC methods to handlers

## Conformance Testing

MCP has an official conformance test suite: https://github.com/modelcontextprotocol/conformance

### SDK Tiers
- **Tier 1**: 100% conformance pass rate (target)
- **Tier 2**: 80% conformance pass rate (initial goal)
- **Tier 3**: No minimum

### Integration
The conformance framework tests via:
- **Server mode**: Framework connects as MCP client to our server
- **Client mode**: Framework starts a test server, runs our client against it

Requires building conformance adapter scripts (see `docs/implementation-plan.md`).

## Critical Rules

1. **JSON-RPC 2.0**: All messages must be valid JSON-RPC 2.0. IDs must be unique per session, never null.
2. **Capability negotiation**: Only use features declared during initialization handshake.
3. **Stdio framing**: Messages are newline-delimited. Must NOT contain embedded newlines.
4. **Streamable HTTP**: POST for sending, GET for SSE listen, `MCP-Session-Id` header for stateful sessions.
5. **Protocol version header**: HTTP requests must include `MCP-Protocol-Version: 2025-11-25`.
6. **Initialization order**: Client sends `initialize` request → server responds → client sends `initialized` notification. No other requests before this completes (except ping).
7. **Tool annotations are untrusted**: Unless from a trusted server.
8. **Partial events**: Sampling and elicitation are client features (server requests them from client).

## Architecture Quick Reference

```
Host Application
  |
  +--> MCP.Client ----[Transport]----> MCP Server (external)
  |       |
  |       +--> initialize / capability negotiation
  |       +--> tools/list, tools/call
  |       +--> resources/list, resources/read
  |       +--> prompts/list, prompts/get
  |
  +--> MCP.Server <---[Transport]---- MCP Client (external)
          |
          +--> register tools, resources, prompts
          +--> handle incoming requests
          +--> sampling/createMessage (request to client)
          +--> elicitation/create (request to client)
```

### Server Features (server provides to client)
- **Tools**: Functions the LLM can call (model-controlled)
- **Resources**: Data/context for the LLM (application-controlled)
- **Prompts**: Templates for user interactions (user-controlled)

### Client Features (client provides to server)
- **Sampling**: Server requests LLM completions via client
- **Roots**: Server queries filesystem boundaries
- **Elicitation**: Server requests user input via client

## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason
