# Architecture Document: MCP Ex

## Document Info
- **Project**: MCP Ex
- **Version**: 0.1.0
- **Date**: 2026-02-08
- **Status**: Phase 4 Complete
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

## 2. Module Map

```
lib/mcp/
  # === Core Protocol (Phase 1 - COMPLETE) ===
  protocol.ex                        # JSON-RPC 2.0 encoding/decoding
  protocol/
    error.ex                         # MCP error codes + JSON-RPC errors
    methods.ex                       # Method name constants
    types/
      tool.ex                        # Tool struct
      tool_annotations.ex            # ToolAnnotations struct
      resource.ex                    # Resource struct
      resource_template.ex           # ResourceTemplate struct
      resource_contents.ex           # ResourceContents struct
      prompt.ex                      # Prompt struct
      prompt_argument.ex             # PromptArgument struct
      prompt_message.ex              # PromptMessage struct
      sampling_message.ex            # SamplingMessage struct
      model_preferences.ex           # ModelPreferences struct
      model_hint.ex                  # ModelHint struct
      root.ex                        # Root struct
      implementation.ex              # Implementation struct (client/server info)
      annotations.ex                 # Content Annotations struct
      icon.ex                        # Icon struct
      content.ex                     # Content type dispatcher
      content/
        text_content.ex              # TextContent struct
        image_content.ex             # ImageContent struct
        audio_content.ex             # AudioContent struct
        embedded_resource.ex         # EmbeddedResource struct
        resource_link.ex             # ResourceLink struct
    capabilities/
      server_capabilities.ex         # ServerCapabilities struct
      client_capabilities.ex         # ClientCapabilities struct
      tool_capabilities.ex           # ToolCapabilities struct
      resource_capabilities.ex       # ResourceCapabilities struct
      prompt_capabilities.ex         # PromptCapabilities struct
      logging_capabilities.ex        # LoggingCapabilities struct
      completion_capabilities.ex     # CompletionCapabilities struct
      sampling_capabilities.ex       # SamplingCapabilities struct
      root_capabilities.ex           # RootCapabilities struct
      elicitation_capabilities.ex    # ElicitationCapabilities struct
    messages/
      request.ex                     # JSON-RPC Request struct
      response.ex                    # JSON-RPC Response struct
      notification.ex                # JSON-RPC Notification struct
      initialize.ex                  # Initialize Params + Result
      ping.ex                        # Ping Params
      tools.ex                       # Tools ListParams/ListResult/CallParams/CallResult
      resources.ex                   # Resources List/Read/Subscribe/Templates types
      prompts.ex                     # Prompts List/Get types
      sampling.ex                    # Sampling CreateMessage Params/Result
      roots.ex                       # Roots List Params/Result
      elicitation.ex                 # Elicitation Params/Result
      logging.ex                     # Logging SetLevel/Message types
      completion.ex                  # Completion Params/Result
      notifications.ex               # Progress/Cancelled/ResourceUpdated params

  # === Transport Layer (Phase 2 - COMPLETE) ===
  transport.ex                       # Transport behaviour (start_link, send_message, close)
  transport/
    stdio.ex                         # Port-based stdin/stdout transport (client + server modes)
    streamable_http/
      client.ex                      # HTTP POST + SSE client transport (Req) (Phase 5)
      server.ex                      # HTTP POST + SSE server transport (Plug) (Phase 5)

  # === Client (Phase 3 - COMPLETE) ===
  client.ex                          # High-level client API (GenServer)

  # === Server (Phase 4 - COMPLETE) ===
  server.ex                          # High-level server API (GenServer)
  server/
    handler.ex                       # Behaviour for tool/resource/prompt handlers
```

---

## 3. Transport Architecture

### Transport Behaviour

```elixir
@callback start_link(opts :: keyword()) :: GenServer.on_start()
@callback send_message(pid :: pid(), message :: map()) :: :ok | {:error, term()}
@callback close(pid :: pid()) :: :ok
```

Transports run as GenServer processes. The owner receives messages via:
- `{:mcp_message, decoded_map}` — incoming JSON-RPC message
- `{:mcp_transport_closed, reason}` — transport closed/disconnected

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
  |     transport_module / transport_pid — the transport process
  |     server_capabilities: ServerCapabilities.t()
  |     server_info: Implementation.t()
  |     client_info / client_capabilities — sent during initialization
  |     pending_requests: %{id => {from, timeout_ref}}
  |     next_id: integer (incrementing)
  |     status: :disconnected | :initializing | :ready | :closed
  |     notification_handler: pid | (method, params -> any)
  |     request_handlers: %{method => callback_fn}
  |
  +-- Public API:
  |     start_link/1         → create GenServer + start transport
  |     connect/1-2          → initialize handshake
  |     list_tools/2         → tools/list
  |     call_tool/3-4        → tools/call
  |     list_resources/2     → resources/list
  |     read_resource/2-3    → resources/read
  |     list_resource_templates/2 → resources/templates/list
  |     subscribe_resource/2-3    → resources/subscribe
  |     unsubscribe_resource/2-3  → resources/unsubscribe
  |     list_prompts/2       → prompts/list
  |     get_prompt/3-4       → prompts/get
  |     ping/1-2             → ping (works pre-init)
  |     close/1              → shutdown
  |     list_all_tools/2     → paginated tools/list
  |     list_all_resources/2 → paginated resources/list
  |     list_all_prompts/2   → paginated prompts/list
  |
  +-- Incoming (from server):
        notifications → dispatch to notification_handler (pid or function)
        requests (sampling, elicitation) → dispatch to request_handlers map
```

### Request/Response Matching

Client assigns incrementing integer IDs to outgoing requests. Each pending request stores `{from, timeout_ref}` in a map. When a response arrives via `{:mcp_message, decoded}`, `Protocol.decode_message/1` classifies it and the matching ID resolves the pending `GenServer.call/3` via `GenServer.reply/2`. Timeouts use `Process.send_after/3`.

### Server-Initiated Requests

MCP servers can send requests to clients (sampling, roots, elicitation). The client dispatches these to callback functions provided at start:

```elixir
{:ok, client} = MCP.Client.start_link(
  transport: {MCP.Transport.Stdio, command: "server", args: []},
  client_info: %{name: "my_app", version: "1.0.0"},
  request_handlers: %{
    "sampling/createMessage" => fn _method, params -> {:ok, result} end,
    "roots/list" => fn _method, _params -> {:ok, %{"roots" => []}} end
  },
  notification_handler: self()  # or fn method, params -> ... end
)
```

---

## 5. Server Architecture

```
MCP.Server (GenServer)
  |
  +-- state:
  |     handler_module / handler_state — user's Handler behaviour implementation
  |     transport_module / transport_pid — the transport process
  |     client_capabilities: ClientCapabilities.t()
  |     client_info: Implementation.t()
  |     server_info / capabilities / instructions — declared at startup
  |     status: :waiting | :ready | :closed
  |     pending_requests: %{id => {from, timeout_ref}}
  |     next_id: integer (incrementing, for server-initiated requests)
  |     log_level: current log level set by client
  |
  +-- Public API:
  |     start_link/1          → create GenServer + start transport + init handler
  |     close/1               → shutdown
  |     transport/1, status/1 → accessors
  |     client_capabilities/1, client_info/1 → from initialization
  |
  +-- Notifications (server → client):
  |     notify_tools_changed/1     → notifications/tools/list_changed
  |     notify_resources_changed/1 → notifications/resources/list_changed
  |     notify_resource_updated/2  → notifications/resources/updated (with uri)
  |     notify_prompts_changed/1   → notifications/prompts/list_changed
  |     log/3-4                    → notifications/message (respects log level)
  |     send_progress/3-4          → notifications/progress
  |
  +-- Server-initiated requests (server → client):
  |     request_sampling/2-3       → sampling/createMessage
  |     request_roots/1-2          → roots/list
  |     request_elicitation/2-3    → elicitation/create
  |
  +-- Incoming (from client):
  |     initialize → respond with capabilities, store client info
  |     notifications/initialized → transition to :ready
  |     ping → empty response (works pre-init)
  |     tools/list, tools/call → dispatch to handler
  |     resources/list, resources/read → dispatch to handler
  |     resources/subscribe, resources/unsubscribe → dispatch to handler
  |     resources/templates/list → dispatch to handler
  |     prompts/list, prompts/get → dispatch to handler
  |     completion/complete → dispatch to handler
  |     logging/setLevel → dispatch to handler + update log_level
  |     unknown method → -32601 error
```

### Handler Behaviour

`MCP.Server.Handler` defines optional callbacks for all server features.
The server auto-detects capabilities by inspecting which callbacks the
handler module exports via `__info__(:functions)`.

```elixir
@callback init(opts) :: {:ok, state}
@callback handle_list_tools(cursor, state) :: {:ok, tools, next_cursor, state}
@callback handle_call_tool(name, arguments, state) :: {:ok, content, state} | {:error, code, msg, state}
@callback handle_list_resources(cursor, state) :: {:ok, resources, next_cursor, state}
@callback handle_read_resource(uri, state) :: {:ok, contents, state} | {:error, code, msg, state}
@callback handle_subscribe(uri, state) :: {:ok, state} | {:error, code, msg, state}
@callback handle_unsubscribe(uri, state) :: {:ok, state} | {:error, code, msg, state}
@callback handle_list_resource_templates(cursor, state) :: {:ok, templates, next_cursor, state}
@callback handle_list_prompts(cursor, state) :: {:ok, prompts, next_cursor, state}
@callback handle_get_prompt(name, arguments, state) :: {:ok, result, state} | {:error, code, msg, state}
@callback handle_complete(ref, argument, state) :: {:ok, completion, state}
@callback handle_set_log_level(level, state) :: {:ok, state}
```

### Request Routing

Routing is inline in the Server GenServer via pattern-matched function clauses
on `%Request{method: "tools/list"}` etc. No separate Router module needed —
Elixir's pattern matching makes this clean and Credo-friendly.

### Capability Auto-Detection

The server inspects `handler_module.__info__(:functions)` to detect which
callbacks are implemented, then builds `%ServerCapabilities{}` accordingly:
- `handle_list_tools/2` → tools capability (with listChanged)
- `handle_list_resources/2` → resources capability (with listChanged)
- `handle_subscribe/2` → resources.subscribe capability
- `handle_list_prompts/2` → prompts capability (with listChanged)
- `handle_set_log_level/2` → logging capability
- `handle_complete/3` → completions capability

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
