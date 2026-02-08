# Architecture Document: MCP Ex

## Document Info
- **Project**: MCP Ex
- **Version**: 0.1.0
- **Date**: 2026-02-08
- **Status**: Planning
- **Protocol**: MCP 2025-11-25

---

## 1. Protocol Overview

MCP uses JSON-RPC 2.0 over stateful connections. The protocol has three phases:

```
1. Initialization    Client sends initialize request
                     Server responds with capabilities
                     Client sends initialized notification

2. Operation         Bidirectional JSON-RPC messages
                     Based on negotiated capabilities

3. Shutdown          Transport-level disconnection
```

### Roles

```
Host Application
  |
  +-- Client 1 ←→ Server A (tools: weather, stocks)
  +-- Client 2 ←→ Server B (resources: files, git)
  +-- Client 3 ←→ Server C (prompts: code review)
```

- **Host**: Application containing one or more clients
- **Client**: Maintains 1:1 session with a server. Provides sampling, roots, elicitation to server.
- **Server**: Provides tools, resources, prompts to client. May request sampling/elicitation from client.

---

## 2. Planned Module Map

```
lib/mcp/
  # === Core Protocol ===
  protocol.ex                        # JSON-RPC 2.0 encoding/decoding
  protocol/
    types.ex                         # All MCP type structs (Tool, Resource, Prompt, Content, etc.)
    messages.ex                      # Request/response/notification structs per MCP method
    capabilities.ex                  # ClientCapabilities, ServerCapabilities
    error.ex                         # MCP error codes + JSON-RPC errors

  # === Transport Layer ===
  transport.ex                       # Transport behaviour (connect, send, receive, close)
  transport/
    stdio.ex                         # Port-based stdin/stdout transport
    streamable_http/
      client.ex                      # HTTP POST + SSE client transport (Req)
      server.ex                      # HTTP POST + SSE server transport (Plug)

  # === Client ===
  client.ex                          # High-level client API (GenServer)
  client/
    session.ex                       # Session state machine (init → operation → shutdown)
    request_registry.ex              # Tracks pending requests by ID for response matching

  # === Server ===
  server.ex                          # High-level server API (GenServer)
  server/
    handler.ex                       # Behaviour for tool/resource/prompt handlers
    router.ex                        # Routes JSON-RPC method → handler
    registry.ex                      # Stores registered tools, resources, prompts
```

---

## 3. Transport Architecture

### Transport Behaviour

```elixir
@callback connect(opts :: keyword()) :: {:ok, state} | {:error, term()}
@callback send_message(state, message :: map()) :: {:ok, state} | {:error, term()}
@callback receive_message(state) :: {:ok, message :: map(), state} | {:error, term()}
@callback close(state) :: :ok
```

### Stdio Transport

```
MCP.Client (GenServer)
  |
  +-- Port (stdin/stdout to subprocess)
  |     Write: JSON + newline to stdin
  |     Read: Newline-delimited JSON from stdout
  |     Stderr: Logged (not protocol messages)
  |
  +-- MCP Server Process (child)
```

- Client launches server as subprocess via `Port.open/2`
- Messages are newline-delimited JSON-RPC (no embedded newlines)
- Server's stderr is captured/logged but not parsed as protocol

### Streamable HTTP Transport

```
Client Side:                          Server Side:
MCP.Client                           MCP.Server
  |                                     |
  +-- POST requests ────────────────→ Plug endpoint
  |   (JSON-RPC in body)               |
  |                                    +-- Response: JSON or SSE stream
  +-- GET (optional) ───────────────→  |
  |   (SSE listen for server msgs)     |
  |                                    +-- MCP-Session-Id header
  +-- MCP-Session-Id header            +-- MCP-Protocol-Version header
  +-- MCP-Protocol-Version header
```

Key Streamable HTTP details:
- Client POST = one JSON-RPC message per request
- Server responds with either `application/json` or `text/event-stream`
- SSE streams can include server-initiated requests/notifications before the response
- Session management via `MCP-Session-Id` header
- Resumability via SSE event IDs and `Last-Event-ID`
- Client can GET to open SSE stream for server-initiated messages

---

## 4. Client Architecture

```
MCP.Client (GenServer)
  |
  +-- state:
  |     transport: transport_state
  |     session_id: string | nil
  |     server_capabilities: ServerCapabilities.t()
  |     pending_requests: %{id => {from, timeout_ref}}
  |     next_id: integer
  |
  +-- Public API:
  |     connect/2           → initialize handshake
  |     list_tools/1-2      → tools/list (with pagination)
  |     call_tool/3         → tools/call
  |     list_resources/1-2  → resources/list
  |     read_resource/2     → resources/read
  |     list_prompts/1-2    → prompts/list
  |     get_prompt/2-3      → prompts/get
  |     subscribe/2         → resources/subscribe
  |     ping/1              → ping
  |     close/1             → shutdown
  |
  +-- Incoming (from server):
        notifications → dispatch to registered handlers
        requests (sampling, elicitation) → dispatch to host callbacks
```

### Request/Response Matching

Client assigns incrementing integer IDs to outgoing requests. When a response arrives with a matching ID, the pending `GenServer.call/3` is resolved. Timeouts are per-request.

### Server-Initiated Requests

MCP servers can send requests to clients (sampling, roots, elicitation). The client dispatches these to callback functions provided at initialization:

```elixir
MCP.Client.connect("server",
  transport: {:stdio, command: "..."},
  on_sampling: fn request -> ... end,
  on_roots_list: fn -> ... end,
  on_elicitation: fn request -> ... end
)
```

---

## 5. Server Architecture

```
MCP.Server (GenServer)
  |
  +-- state:
  |     transport: transport_state
  |     client_capabilities: ClientCapabilities.t()
  |     tools: %{name => ToolDef.t()}
  |     resources: %{uri => ResourceDef.t()}
  |     prompts: %{name => PromptDef.t()}
  |     session_id: string | nil
  |
  +-- Registration API:
  |     add_tool/2
  |     add_resource/2
  |     add_prompt/2
  |     notify_tools_changed/1
  |     notify_resources_changed/1
  |
  +-- Incoming (from client):
  |     initialize → respond with capabilities
  |     tools/list → return registered tools
  |     tools/call → dispatch to tool handler
  |     resources/list → return registered resources
  |     resources/read → dispatch to resource handler
  |     prompts/list → return registered prompts
  |     prompts/get → dispatch to prompt handler
  |
  +-- Outgoing (to client):
        sampling/createMessage → request LLM completion
        roots/list → request filesystem roots
        elicitation/create → request user input
```

---

## 6. JSON-RPC 2.0 Message Types

### Request
```json
{"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
```

### Response (success)
```json
{"jsonrpc": "2.0", "id": 1, "result": {"tools": [...]}}
```

### Response (error)
```json
{"jsonrpc": "2.0", "id": 1, "error": {"code": -32602, "message": "Unknown tool"}}
```

### Notification (no response expected)
```json
{"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}
```

### Standard Error Codes
| Code | Meaning |
|------|---------|
| -32700 | Parse error |
| -32600 | Invalid request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |
| -32002 | Resource not found |
| -32042 | URL elicitation required |
| -1 | User rejected sampling |

---

## 7. Capability Negotiation

During initialization, both sides declare what they support:

### Server Capabilities
```elixir
%ServerCapabilities{
  tools: %{listChanged: true},
  resources: %{subscribe: true, listChanged: true},
  prompts: %{listChanged: true},
  logging: %{},
  completions: %{}
}
```

### Client Capabilities
```elixir
%ClientCapabilities{
  roots: %{listChanged: true},
  sampling: %{tools: %{}},
  elicitation: %{form: %{}, url: %{}}
}
```

Both sides MUST respect declared capabilities throughout the session.

---

## 8. Content Types

Tool results, prompts, and resources can contain multiple content types:

| Type | Fields | Usage |
|------|--------|-------|
| `TextContent` | type: "text", text | Most common |
| `ImageContent` | type: "image", data (base64), mimeType | Visual content |
| `AudioContent` | type: "audio", data (base64), mimeType | Audio content |
| `ResourceContent` | type: "resource", resource (uri, text/blob) | Embedded resources |
| `ResourceLink` | type: "resource_link", uri, name, mimeType | Links to resources |

---

## 9. Elixir/OTP Design Patterns

| MCP Concept | Elixir Implementation |
|-------------|----------------------|
| Client session | GenServer per connection |
| Server instance | GenServer per connection |
| Stdio transport | Port (Erlang port for subprocess) |
| SSE stream | `Req` + stream processing / `Plug.Conn` chunked |
| Request/response matching | Map of `%{id => from}` in GenServer state |
| Notifications | `send/2` to registered handler processes |
| Tool registration | Map in GenServer state |
| JSON-RPC framing | `Jason.encode!/1` + `Jason.decode!/1` |
| Session lifecycle | GenServer init/handle_call/terminate |
| Concurrent clients | Supervisor with dynamic children |
| Pagination | Cursor-based, lazy with Stream |

---

## 10. Testing Strategy

### Unit Tests
- Protocol encoding/decoding (JSON-RPC messages)
- Type serialization/deserialization
- Capability negotiation logic
- Transport message framing (stdio, HTTP)
- Client API (with mock transport)
- Server API (with mock transport)

### Integration Tests
- Client ↔ Server over stdio (in-process)
- Client ↔ Server over HTTP (localhost)
- Full lifecycle: init → operations → shutdown

### Conformance Tests
- Official MCP conformance suite via `npx @modelcontextprotocol/conformance`
- Server mode: conformance framework connects to our server
- Client mode: conformance framework tests our client
- Expected failures baseline file for incremental compliance
- GitHub Actions integration for CI

---

## 11. Dependencies

### Required
| Dep | Purpose |
|-----|---------|
| `jason` | JSON encoding/decoding |
| `elixir_uuid` | ID generation |

### Optional
| Dep | Purpose | When Needed |
|-----|---------|-------------|
| `req` | HTTP client | Streamable HTTP client transport |
| `plug` | HTTP server framework | Streamable HTTP server transport |
| `bandit` | HTTP server | Streamable HTTP server transport |
| `castore` | TLS certificates | HTTPS connections |

### Dev/Test
| Dep | Purpose |
|-----|---------|
| `dialyxir` | Type checking |
| `credo` | Static analysis |
| `ex_doc` | Documentation |
