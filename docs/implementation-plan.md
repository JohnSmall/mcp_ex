# Implementation Plan: MCP Ex

## Document Info
- **Project**: MCP Ex
- **Version**: 0.1.0
- **Date**: 2026-02-08
- **Status**: Phase 3 Complete
- **Protocol**: MCP 2025-11-25

---

## Overview

The implementation is organized into 6 phases, each building on the previous. Each phase produces a working, testable subset of functionality with `mix test && mix credo && mix dialyzer` passing.

**Reference SDKs** (clone locally before starting):
```bash
git clone https://github.com/modelcontextprotocol/go-sdk /workspace/mcp-go-sdk
git clone https://github.com/modelcontextprotocol/python-sdk /workspace/mcp-python-sdk
git clone https://github.com/modelcontextprotocol/ruby-sdk /workspace/mcp-ruby-sdk
git clone https://github.com/modelcontextprotocol/typescript-sdk /workspace/mcp-typescript-sdk
git clone https://github.com/modelcontextprotocol/conformance /workspace/mcp-conformance
```

---

## Phase 1: Project Setup + Core Protocol Types

**Goal**: Establish Mix project, define all MCP type structs, implement JSON-RPC 2.0 message encoding/decoding.

**Dependencies**: None

### Tasks

- [x] **1.1** Create Mix project at `/workspace/mcp_ex`
  - `mix new mcp_ex --sup`
  - Configure mix.exs with deps: jason, elixir_uuid, dialyxir, credo, ex_doc
  - Set Elixir >= 1.17, OTP >= 26
  - Application name `:mcp_ex`

- [x] **1.2** Define protocol error module (`lib/mcp/protocol/error.ex`)
  - `MCP.Protocol.Error` struct: code, message, data
  - Standard JSON-RPC error codes: -32700 (parse), -32600 (invalid request), -32601 (method not found), -32602 (invalid params), -32603 (internal error)
  - MCP-specific codes: -32002 (resource not found), -32042 (URL elicitation required), -1 (user rejected sampling)
  - Constructor helpers: `parse_error/0`, `invalid_request/0`, `method_not_found/0`, `invalid_params/1`, `internal_error/1`

- [x] **1.3** Define core MCP type structs (`lib/mcp/protocol/types/`)
  - `MCP.Protocol.Types.Tool` — name (required), title, description, inputSchema, outputSchema, annotations, icons
  - `MCP.Protocol.Types.Resource` — uri (required), name (required), title, description, mimeType, size, annotations, icons
  - `MCP.Protocol.Types.ResourceTemplate` — uriTemplate, name, title, description, mimeType, icons
  - `MCP.Protocol.Types.Prompt` — name (required), title, description, arguments (list), icons
  - `MCP.Protocol.Types.PromptArgument` — name (required), description, required (boolean)
  - `MCP.Protocol.Types.PromptMessage` — role ("user"/"assistant"), content
  - Content types (can share file or separate):
    - `TextContent` — type: "text", text
    - `ImageContent` — type: "image", data (base64), mimeType
    - `AudioContent` — type: "audio", data (base64), mimeType
    - `ResourceContent` — type: "resource", resource (embedded uri + text/blob)
    - `ResourceLink` — type: "resource_link", uri, name, mimeType
  - `ToolResult` — content (list), structuredContent (map | nil), isError (boolean)
  - `Implementation` — name, version, title, description, icons, websiteUrl
  - `ToolAnnotations` — title, readOnlyHint, destructiveHint, idempotentHint, openWorldHint
  - `Icon` — url, mediaType
  - JSON serialization: `to_map/1` and `from_map/1` for each type (snake_case internal, camelCase wire)

- [x] **1.4** Define capability structs (`lib/mcp/protocol/capabilities/`)
  - `MCP.Protocol.Capabilities.ServerCapabilities` — tools, resources, prompts, logging, completions, experimental
  - `MCP.Protocol.Capabilities.ClientCapabilities` — roots, sampling, elicitation, experimental
  - Each sub-capability as a nested map (e.g., tools: %{listChanged: true})
  - `to_map/1` and `from_map/1` for wire format

- [x] **1.5** Define JSON-RPC message structs (`lib/mcp/protocol/messages/`)
  - `MCP.Protocol.Messages.Request` — jsonrpc: "2.0", id, method, params
  - `MCP.Protocol.Messages.Response` — jsonrpc: "2.0", id, result | error
  - `MCP.Protocol.Messages.Notification` — jsonrpc: "2.0", method, params (no id)
  - Validation: requests MUST have id (integer or string, never null), notifications MUST NOT

- [x] **1.6** Implement JSON-RPC 2.0 protocol module (`lib/mcp/protocol.ex`)
  - `MCP.Protocol.encode/1` — struct → JSON string (via Jason)
  - `MCP.Protocol.decode/1` — JSON string → struct
  - `MCP.Protocol.encode_message/1` — struct → map (for transport layer)
  - `MCP.Protocol.decode_message/1` — map → struct (classifies as request/response/notification)
  - ID generation: incrementing integers (managed by caller, not protocol module)
  - Batch support: not required (MCP doesn't use JSON-RPC batches)

- [x] **1.7** Define all MCP method-specific message types (`lib/mcp/protocol/messages/`)
  - One module per feature group, each defining request params + result structs:
  - `initialize.ex`: InitializeParams (protocolVersion, capabilities, clientInfo), InitializeResult (protocolVersion, capabilities, serverInfo, instructions)
  - `tools.ex`: ListToolsParams (cursor), ListToolsResult (tools, nextCursor), CallToolParams (name, arguments), CallToolResult (content, structuredContent, isError)
  - `resources.ex`: ListResourcesParams, ListResourcesResult, ReadResourceParams, ReadResourceResult, SubscribeParams, UnsubscribeParams, ListResourceTemplatesParams, ListResourceTemplatesResult
  - `prompts.ex`: ListPromptsParams, ListPromptsResult, GetPromptParams, GetPromptResult (description, messages)
  - `sampling.ex`: CreateMessageParams (messages, modelPreferences, systemPrompt, maxTokens, etc.), CreateMessageResult (role, content, model, stopReason)
  - `roots.ex`: ListRootsResult (roots list with uri + name)
  - `elicitation.ex`: ElicitParams (message, requestedSchema), ElicitResult (action, content)
  - `logging.ex`: SetLevelParams (level), LoggingMessageNotification (level, logger, data)
  - `completion.ex`: CompleteParams (ref, argument), CompleteResult (values, total, hasMore)
  - `ping.ex`: PingParams (empty), PingResult (empty map)

### Verification
```bash
mix test       # Protocol encoding/decoding, type round-trips
mix credo
mix dialyzer
```

### Go SDK Reference
- Types: `/workspace/mcp-go-sdk/mcp/types.go`
- Messages: `/workspace/mcp-go-sdk/mcp/mcp.go`
- Protocol: `/workspace/mcp-go-sdk/internal/jsonrpc/`

---

## Phase 2: Transport Layer + Stdio Transport

**Goal**: Define transport behaviour, implement stdio transport, test with raw JSON-RPC messages.

**Dependencies**: Phase 1

### Tasks

- [x] **2.1** Define transport behaviour (`lib/mcp/transport.ex`)
  - `MCP.Transport` behaviour with callbacks:
    - `start_link(opts :: keyword()) :: GenServer.on_start()`
    - `send_message(pid, message :: map()) :: :ok | {:error, term()}`
    - `close(pid) :: :ok`
  - Transport runs as a GenServer process owned by the client/server
  - Incoming messages delivered via `send(owner, {:mcp_message, decoded})`
  - Transport closure signaled via `send(owner, {:mcp_transport_closed, reason})`

- [x] **2.2** Implement stdio transport (`lib/mcp/transport/stdio.ex`)
  - `MCP.Transport.Stdio` — GenServer implementing Transport behaviour
  - **Client mode**: Opens an Erlang Port (`Port.open({:spawn_executable, ...}`) to subprocess
    - Writes: JSON + `\n` to stdin
    - Reads: Newline-delimited JSON from stdout (buffer partial reads)
    - Stderr: Goes to parent process stderr (not protocol)
  - **Server mode**: Reads from `:stdio` (stdin), writes to stdout
    - Uses `:io.get_line/1` in a spawned reader process
    - Writes JSON + `\n` to stdout
  - Message framing:
    - Output: `Jason.encode!(message) <> "\n"` — MUST NOT contain embedded newlines
    - Input: Buffer incoming data, split on `\n`, decode each complete line
  - Deliver decoded messages to owner process via `send(owner, {:mcp_message, decoded})`
  - Handle Port exit / EOF → notify owner via `send(owner, {:mcp_transport_closed, reason})`

- [x] **2.3** Write transport test helpers (`test/support/`)
  - `MCP.Test.MockTransport` — In-memory transport for unit testing client/server
    - Collects sent messages in a list
    - Allows injecting incoming messages via `inject/2`
    - Tracks close state via `closed?/1`
  - `test/support/echo_server.exs` — Simple echo script for stdio testing
    - Reads newline-delimited JSON from stdin, echoes params in result
    - Special "exit" method causes shutdown
  - 10 tests total: 4 MockTransport unit tests + 6 Stdio integration tests

### Verification
```bash
mix test       # Transport behaviour, stdio framing, mock transport
mix credo
mix dialyzer
```

### Go SDK Reference
- Transport interface: `/workspace/mcp-go-sdk/mcp/transport.go`
- Stdio transport: `/workspace/mcp-go-sdk/mcp/stdio.go`

---

## Phase 3: Client (GenServer + Initialize + Core Operations)

**Goal**: Implement MCP client as a GenServer that can connect to servers, perform initialization handshake, and call tools/resources/prompts.

**Dependencies**: Phase 2

### Tasks

- [x] **3.1** Implement client GenServer (`lib/mcp/client.ex`)
  - `MCP.Client` — GenServer holding transport, session state, pending requests
  - State: `transport_module`, `transport_pid`, `server_capabilities`, `server_info`,
    `client_info`, `client_capabilities`, `pending_requests` (`%{id => {from, timeout_ref}}`),
    `next_id` (incrementing integer), `status` (`:disconnected | :initializing | :ready | :closed`),
    `notification_handler` (pid or function), `request_handlers` (`%{method => callback_fn}`),
    `request_timeout`, `connect_from`
  - Transport started in `init/1` with client as owner; supports `{module, opts}` spec

- [x] **3.2** Implement initialization handshake
  - `MCP.Client.connect/1-2` — sends `initialize` request, blocks until response
  - On success: stores server capabilities + server info, sends `initialized` notification
  - Enforces: no requests (except ping) before initialization completes
  - Returns `{:ok, %{server_info, server_capabilities, protocol_version, instructions}}`

- [x] **3.3** Implement request/response matching
  - Each outgoing request gets a unique integer ID and stores `{from, timeout_ref}` in pending_requests
  - `handle_info({:mcp_message, message}, state)` uses `Protocol.decode_message/1` to route:
    - Response → match pending request, reply via `GenServer.reply/2`
    - Request → server-initiated, dispatch to `request_handlers` callback
    - Notification → dispatch to `notification_handler`
  - Timeout via `Process.send_after(self(), {:request_timeout, id}, timeout_ms)`
  - Transport closed: replies `{:error, {:transport_closed, reason}}` to all pending

- [x] **3.4** Implement core client API
  - `list_tools/2`, `call_tool/3-4`, `list_resources/2`, `read_resource/2-3`,
    `list_resource_templates/2`, `subscribe_resource/2-3`, `unsubscribe_resource/2-3`,
    `list_prompts/2`, `get_prompt/3-4`, `ping/1-2`, `close/1`
  - Helper accessors: `transport/1`, `status/1`, `server_capabilities/1`, `server_info/1`
  - All operations use GenServer.call with configurable timeout

- [x] **3.5** Implement pagination helpers
  - `list_all_tools/2`, `list_all_resources/2`, `list_all_resource_templates/2`, `list_all_prompts/2`
  - Recursive pagination using `cursor`/`nextCursor` from responses
  - Terminates when `nextCursor` is nil

- [x] **3.6** Implement notification handling
  - Dispatches to pid (via `send(pid, {:mcp_notification, method, params})`) or function handler
  - Server-initiated requests dispatched to `request_handlers` map, responds with result or error
  - Unknown server requests get method_not_found error response
  - 33 tests total covering all client functionality

### Verification
```bash
mix test       # Client lifecycle, handshake, tools/resources/prompts, pagination, notifications
mix credo
mix dialyzer
```

### Go SDK Reference
- Client: `/workspace/mcp-go-sdk/mcp/client.go`
- Client session: `/workspace/mcp-go-sdk/mcp/client_session.go`

---

## Phase 4: Server (GenServer + Handler Behaviour + Core Operations)

**Goal**: Implement MCP server as a GenServer that handles initialization, responds to tool/resource/prompt requests, and supports change notifications.

**Dependencies**: Phase 2

### Tasks

- [x] **4.1** Define server handler behaviour (`lib/mcp/server/handler.ex`) — DONE
  - `MCP.Server.Handler` behaviour with 12 optional callbacks + required `init/1`
  - Callbacks: handle_list_tools/2, handle_call_tool/3, handle_list_resources/2,
    handle_read_resource/2, handle_subscribe/2, handle_unsubscribe/2,
    handle_list_resource_templates/2, handle_list_prompts/2, handle_get_prompt/3,
    handle_complete/3, handle_set_log_level/2
  - All callbacks use `@optional_callbacks` — server auto-detects capabilities

- [x] **4.2** Implement server GenServer (`lib/mcp/server.ex`) — DONE
  - ~490 lines, GenServer managing transport + handler dispatch
  - State: handler_module/handler_state, transport_module/transport_pid,
    client_capabilities/client_info, server_info, capabilities (auto-detected),
    status (:waiting → :ready → :closed), pending_requests, next_id, log_level
  - Auto-detect capabilities via `handler_module.__info__(:functions)`

- [x] **4.3** Implement initialization handshake (server side) — DONE
  - Receive `initialize` → respond with capabilities + server info + instructions
  - Receive `notifications/initialized` → transition to :ready
  - Reject non-ping requests before initialization (returns -32600)
  - Reject duplicate initialization (returns -32600)
  - Ping works in any state

- [x] **4.4** Implement request routing — DONE (inline, no separate Router module)
  - Pattern-matched function clauses on `%Request{method: "tools/list"}` etc.
  - 11 method routes + unknown method → -32601 error
  - No separate Router module needed — Elixir pattern matching keeps it clean

- [x] **4.5** Implement server-initiated messages — DONE
  - Notifications: notify_tools_changed/1, notify_resources_changed/1,
    notify_resource_updated/2, notify_prompts_changed/1, log/3-4, send_progress/3-4
  - Server-to-client requests: request_sampling/2-3, request_roots/1-2, request_elicitation/2-3
  - Log level filtering: messages below threshold silently dropped
  - Notifications silently dropped when not :ready

- [x] **4.6** Simple handler helpers — DEFERRED
  - SimpleHandler deferred to a future phase; TestHandler in tests demonstrates the pattern
  - Users implement Handler behaviour directly (straightforward with optional callbacks)

- [x] **4.7** Server run modes — PARTIALLY DONE
  - `start_link/1` implemented for supervised mode
  - Blocking `run/2` deferred to Phase 5 (Streamable HTTP integration)

### Verification
```bash
mix test       # Server lifecycle, routing, handler dispatch, notifications, simple handler
mix credo
mix dialyzer
```

### Go SDK Reference
- Server: `/workspace/mcp-go-sdk/mcp/server.go`
- Server session: `/workspace/mcp-go-sdk/mcp/server_session.go`

---

## Phase 5: Streamable HTTP Transport

**Goal**: Implement the Streamable HTTP transport for both client and server sides.

**Dependencies**: Phase 3 (client), Phase 4 (server)

### Tasks

- [x] **5.1** Add optional HTTP dependencies
  - `{:req, "~> 0.5", optional: true}` — HTTP client (for Streamable HTTP client)
  - `{:plug, "~> 1.16", optional: true}` — HTTP framework (for Streamable HTTP server)
  - `{:bandit, "~> 1.5", optional: true}` — HTTP server (for Streamable HTTP server)
  - Existing stdio transport works with zero HTTP deps

- [x] **5.2** Implement Streamable HTTP client transport (`lib/mcp/transport/streamable_http/client.ex`)
  - `MCP.Transport.StreamableHTTP.Client` — GenServer implementing Transport behaviour
  - Sends JSON-RPC via HTTP POST using Req library
  - Required headers: Content-Type, Accept, MCP-Protocol-Version, MCP-Session-Id
  - Response handling: application/json (direct) or text/event-stream (SSE parsing)
  - Session management: extracts MCP-Session-Id from init response, includes in subsequent
  - On close: sends HTTP DELETE to session endpoint

- [x] **5.3** Implement Streamable HTTP server transport
  - Three-module design:
    - `StreamableHTTP.Plug` (`plug.ex`) — Plug handling POST/GET/DELETE
    - `StreamableHTTP.Server` (`server.ex`) — Transport GenServer (bridges Plug ↔ MCP.Server)
    - `StreamableHTTP.PreStarted` (`pre_started.ex`) — Adapter for reusing transport pid
  - POST: parse JSON-RPC, route to session, return JSON or SSE response
  - GET: SSE stream endpoint for server-initiated messages
  - DELETE: terminate session, clean up ETS registry
  - ETS-based session registry mapping session_id → transport_pid
  - Supports both stateful (with session IDs) and stateless modes
  - Protocol version header validation on non-initialize requests

- [x] **5.4** Implement SSE parsing/encoding utilities (`lib/mcp/transport/sse.ex`)
  - `encode_event/1` — encode SSE event map to wire format
  - `encode_message/2` — encode JSON-RPC message as SSE event with options (id, event type)
  - `decode_event/1` — parse SSE event text into event map
  - `new_parser/0`, `feed/2` — incremental stream parser for chunked SSE data
  - 20 tests covering encoding, decoding, multi-line data, stream parsing, round-trip

- [x] **5.5** Integration testing (client ↔ server over HTTP)
  - 12 integration tests using Bandit + Plug + MCP.Server + MCP.Client
  - Full lifecycle: initialize → tools/list → tools/call → close
  - Test list/read resources, error handling, ping
  - Test JSON response mode (enable_json_response: true)
  - Test session management (MCP-Session-Id header extraction and inclusion)
  - Test raw HTTP requests (protocol version validation, 405 for unsupported methods)
  - 20 SSE unit tests covering encoding, decoding, stream parsing, round-trip
  - Total: 215 tests, 0 failures, credo clean, dialyzer clean

### Verification
```bash
mix test       # HTTP transport, SSE parsing, client-server integration
mix credo
mix dialyzer
```

### Go SDK Reference
- Streamable HTTP: `/workspace/mcp-go-sdk/mcp/sse.go`, `/workspace/mcp-go-sdk/mcp/streamable_http.go`

---

## Phase 6: Client Features (Sampling, Roots, Elicitation) + Conformance

**Goal**: Implement client-side features (server requests things from client), progress/cancellation, and integrate with official MCP conformance test suite.

**Dependencies**: Phase 3, Phase 4

### Tasks

- [x] **6.1** Implement sampling client feature
  - `:on_sampling` callback option auto-advertises `sampling` capability
  - Auto-populates `request_handlers` map with `"sampling/createMessage"` handler
  - Callback signature: `fn(params) -> {:ok, result} | {:error, %Error{}}`
  - If no callback registered: responds with method not found error
  - 4 tests: capability advertisement, callback dispatch, error handling, missing handler

- [x] **6.2** Implement roots client feature
  - `:on_roots_list` callback option auto-advertises `roots` capability with `listChanged: true`
  - Auto-populates `request_handlers` map with `"roots/list"` handler
  - `MCP.Client.notify_roots_changed/1` sends `notifications/roots/list_changed` to server
  - 4 tests: capability advertisement, callback dispatch, notify_roots_changed, dropped when not ready

- [x] **6.3** Implement elicitation client feature
  - `:on_elicitation` callback option auto-advertises `elicitation` capability (form + url)
  - Auto-populates `request_handlers` map with `"elicitation/create"` handler
  - 3 tests: capability advertisement, callback dispatch (accept/decline)

- [x] **6.4** Implement progress notifications
  - Server already sends via `MCP.Server.send_progress/3-4`
  - Client dispatches via `notification_handler` (pid or function)
  - 1 test: progress notification dispatch to handler

- [x] **6.5** Implement request cancellation
  - `MCP.Client.cancel/2-3` sends `notifications/cancelled` with requestId and optional reason
  - Server already handles incoming cancellation (logs and acknowledges)
  - 3 tests: cancellation with/without reason, dropped when closed

- [x] **6.6** Build conformance test adapter scripts
  - `conformance/server_handler.ex` — Handler with all 12 conformance test tools, 3 resources,
    4 prompts, resource templates, subscriptions, logging, completion
  - `conformance/server_adapter.exs` — Starts Bandit HTTP server with Streamable HTTP Plug
  - `conformance/client_adapter.exs` — Client adapter with scenario dispatch
  - `conformance/expected_failures.yml` — Baseline of 7 expected failures

- [x] **6.7** Run conformance test suite
  - Server: `mix run conformance/server_adapter.exs 3099`
  - Test: `npx @modelcontextprotocol/conformance server --url http://localhost:3099/mcp`
  - **Result: 24/30 passed (80%) — Tier 2 achieved**
  - 7 failures all require SSE streaming within tool execution (architectural limitation)
  - DNS rebinding protection implemented in Plug (Host/Origin header validation)

- [x] **6.8** Integration tests: client ↔ server in-process
  - BridgeTransport connects Client ↔ Server GenServers in-memory
  - 30 integration tests covering: initialization, tools, resources, prompts,
    pagination, sampling, roots, elicitation, progress, cancellation, logging, error handling
  - Full lifecycle: connect → operate → close
  - Test all client features: sampling, roots, elicitation
  - Test progress and cancellation
  - Test error handling (unknown method, invalid params, server errors)

### Verification
```bash
mix test                    # All unit + integration tests
mix credo
mix dialyzer
npx @modelcontextprotocol/conformance test --server "..."   # Conformance
```

### Go SDK Reference
- Conformance: `/workspace/mcp-conformance/`
- SDK integration guide: `/workspace/mcp-conformance/SDK_INTEGRATION.md`

---

## Dependency Graph

```
Phase 1: Core Protocol Types
    |
    v
Phase 2: Transport + Stdio
    |
    +------------------+
    |                  |
    v                  v
Phase 3: Client    Phase 4: Server
    |                  |
    +--------+---------+
             |
             v
Phase 5: Streamable HTTP Transport
             |
             v
Phase 6: Client Features + Conformance
```

Phases 3 and 4 can be developed in parallel after Phase 2.

---

## Estimated Test Counts

| Phase | New Tests | Running Total |
|-------|-----------|---------------|
| Phase 1: Core Protocol | 93 | 93 |
| Phase 2: Transport + Stdio | 10 | 103 |
| Phase 3: Client | ~35 | 95 |
| Phase 4: Server | ~35 | 130 |
| Phase 5: Streamable HTTP | ~25 | 155 |
| Phase 6: Features + Conformance | ~30 | 185 |

---

## Go SDK Reference Files (Quick Lookup)

| Component | Go Source |
|-----------|----------|
| Protocol types | `/workspace/mcp-go-sdk/mcp/types.go` |
| JSON-RPC messages | `/workspace/mcp-go-sdk/mcp/mcp.go` |
| Transport interface | `/workspace/mcp-go-sdk/mcp/transport.go` |
| Stdio transport | `/workspace/mcp-go-sdk/mcp/stdio.go` |
| Streamable HTTP | `/workspace/mcp-go-sdk/mcp/streamable_http.go` |
| SSE utilities | `/workspace/mcp-go-sdk/mcp/sse.go` |
| Client | `/workspace/mcp-go-sdk/mcp/client.go` |
| Client session | `/workspace/mcp-go-sdk/mcp/client_session.go` |
| Server | `/workspace/mcp-go-sdk/mcp/server.go` |
| Server session | `/workspace/mcp-go-sdk/mcp/server_session.go` |
| Conformance integration | `/workspace/mcp-conformance/SDK_INTEGRATION.md` |

---

## Key Design Decisions

### 1. GenServer Per Connection
Each MCP client and server instance is a GenServer. This maps naturally to MCP's stateful session model — each connection has its own state, capabilities, and pending requests.

### 2. Transport as Separate Process
Transports run as their own GenServer (or Port wrapper), communicating with the client/server via standard Erlang messages. This decouples protocol logic from I/O, making testing and transport swapping straightforward.

### 3. Handler Behaviour for Server
Server features are implemented via a behaviour (`MCP.Server.Handler`), not by passing functions. This provides compile-time checking, documentation, and a clear extension point. The `SimpleHandler` convenience module covers simple use cases.

### 4. Optional HTTP Dependencies
HTTP deps (req, plug, bandit) are optional. A stdio-only deployment has zero HTTP dependencies. This keeps the package lightweight for CLI tools and embedded systems.

### 5. camelCase on Wire, snake_case Internal
MCP spec uses camelCase (JSON). Elixir uses snake_case. Type structs use snake_case internally with `to_map/1`/`from_map/1` handling the conversion. Jason encoders can be derived where needed.

### 6. Conformance-Driven Development
After the core is working, use the official conformance suite to find gaps and edge cases rather than guessing at spec compliance.
