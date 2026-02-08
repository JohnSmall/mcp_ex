# Implementation Plan: MCP Ex

## Document Info
- **Project**: MCP Ex
- **Version**: 0.1.0
- **Date**: 2026-02-08
- **Status**: Planning
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

- [ ] **1.1** Create Mix project at `/workspace/mcp_ex`
  - `mix new mcp_ex --sup`
  - Configure mix.exs with deps: jason, elixir_uuid, dialyxir, credo, ex_doc
  - Set Elixir >= 1.17, OTP >= 26
  - Application name `:mcp_ex`

- [ ] **1.2** Define protocol error module (`lib/mcp/protocol/error.ex`)
  - `MCP.Protocol.Error` struct: code, message, data
  - Standard JSON-RPC error codes: -32700 (parse), -32600 (invalid request), -32601 (method not found), -32602 (invalid params), -32603 (internal error)
  - MCP-specific codes: -32002 (resource not found), -32042 (URL elicitation required), -1 (user rejected sampling)
  - Constructor helpers: `parse_error/0`, `invalid_request/0`, `method_not_found/0`, `invalid_params/1`, `internal_error/1`

- [ ] **1.3** Define core MCP type structs (`lib/mcp/protocol/types.ex`)
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

- [ ] **1.4** Define capability structs (`lib/mcp/protocol/capabilities.ex`)
  - `MCP.Protocol.Capabilities.ServerCapabilities` — tools, resources, prompts, logging, completions, experimental
  - `MCP.Protocol.Capabilities.ClientCapabilities` — roots, sampling, elicitation, experimental
  - Each sub-capability as a nested map (e.g., tools: %{listChanged: true})
  - `to_map/1` and `from_map/1` for wire format

- [ ] **1.5** Define JSON-RPC message structs (`lib/mcp/protocol/messages.ex`)
  - `MCP.Protocol.Messages.Request` — jsonrpc: "2.0", id, method, params
  - `MCP.Protocol.Messages.Response` — jsonrpc: "2.0", id, result | error
  - `MCP.Protocol.Messages.Notification` — jsonrpc: "2.0", method, params (no id)
  - Validation: requests MUST have id (integer or string, never null), notifications MUST NOT

- [ ] **1.6** Implement JSON-RPC 2.0 protocol module (`lib/mcp/protocol.ex`)
  - `MCP.Protocol.encode/1` — struct → JSON string (via Jason)
  - `MCP.Protocol.decode/1` — JSON string → struct
  - `MCP.Protocol.encode_message/1` — struct → map (for transport layer)
  - `MCP.Protocol.decode_message/1` — map → struct (classifies as request/response/notification)
  - ID generation: incrementing integers (managed by caller, not protocol module)
  - Batch support: not required (MCP doesn't use JSON-RPC batches)

- [ ] **1.7** Define all MCP method-specific message types (`lib/mcp/protocol/messages/`)
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

- [ ] **2.1** Define transport behaviour (`lib/mcp/transport.ex`)
  - `MCP.Transport` behaviour with callbacks:
    - `connect(opts :: keyword()) :: {:ok, state} | {:error, term()}`
    - `send_message(state, message :: iodata()) :: {:ok, state} | {:error, term()}`
    - `close(state) :: :ok`
  - Transport is responsible for framing (newline for stdio, HTTP for streamable)
  - Incoming messages delivered via `send/2` to the owner process (GenServer)
  - Transport runs as a process (GenServer) owned by the client/server

- [ ] **2.2** Implement stdio transport (`lib/mcp/transport/stdio.ex`)
  - `MCP.Transport.Stdio` — GenServer implementing Transport behaviour
  - **Client mode**: Opens an Erlang Port (`Port.open({:spawn_executable, ...}`) to subprocess
    - Writes: JSON + `\n` to stdin
    - Reads: Newline-delimited JSON from stdout (buffer partial reads)
    - Stderr: Captured, logged via Logger, NOT parsed as protocol messages
  - **Server mode**: Reads from `:stdio` (stdin), writes to stdout
    - Uses `:io.get_line/1` or equivalent for reading
    - Writes JSON + `\n` to stdout
  - Message framing:
    - Output: `Jason.encode!(message) <> "\n"` — MUST NOT contain embedded newlines
    - Input: Buffer incoming data, split on `\n`, decode each complete line
  - Deliver decoded messages to owner process via `send(owner, {:mcp_message, decoded})`
  - Handle Port exit / EOF → notify owner via `send(owner, {:mcp_transport_closed, reason})`

- [ ] **2.3** Write transport test helpers (`test/support/`)
  - `MCP.Test.MockTransport` — In-memory transport for unit testing client/server
    - Collects sent messages in a list
    - Allows injecting incoming messages
  - `MCP.Test.EchoServer` — Simple script that echoes JSON-RPC for stdio testing
  - Helpers for building valid JSON-RPC request/response maps

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

- [ ] **3.1** Implement client GenServer (`lib/mcp/client.ex`)
  - `MCP.Client` — GenServer holding transport, session state, pending requests
  - State:
    - `transport_module` / `transport_pid` — the transport process
    - `server_capabilities` — negotiated server capabilities
    - `server_info` — server's Implementation struct
    - `session_id` — for Streamable HTTP (nil for stdio)
    - `pending_requests` — `%{id => {from, timeout_ref}}` for request/response matching
    - `next_id` — incrementing integer for outgoing request IDs
    - `status` — `:connecting | :initializing | :ready | :closed`
    - `notification_handler` — pid or function for incoming notifications
    - `callbacks` — map of `%{method => callback_fn}` for server-initiated requests

- [ ] **3.2** Implement initialization handshake
  - `MCP.Client.connect/2` — starts transport, sends `initialize` request
  - Initialize request params: protocolVersion ("2025-11-25"), capabilities, clientInfo
  - On response: store server capabilities + server info, send `initialized` notification
  - Enforce: no requests (except ping) before initialization completes
  - Version negotiation: server may respond with different protocol version — client must accept or disconnect

- [ ] **3.3** Implement request/response matching
  - Each outgoing request gets a unique integer ID and stores `{from, timeout_ref}` in pending_requests
  - `handle_info({:mcp_message, message}, state)` routes:
    - Response (has `id`, has `result` or `error`): match pending request, reply via `GenServer.reply/2`
    - Request (has `id`, has `method`): server-initiated, dispatch to callback
    - Notification (no `id`, has `method`): dispatch to notification handler
  - Timeout: `Process.send_after(self(), {:request_timeout, id}, timeout_ms)`
  - On timeout: reply `{:error, :timeout}`, remove from pending

- [ ] **3.4** Implement core client API
  - `list_tools(client, opts \\ [])` — `tools/list` request, returns `{:ok, tools, next_cursor}`
  - `call_tool(client, name, arguments, opts \\ [])` — `tools/call` request
  - `list_resources(client, opts \\ [])` — `resources/list` request
  - `read_resource(client, uri)` — `resources/read` request
  - `list_resource_templates(client, opts \\ [])` — `resources/templates/list`
  - `subscribe_resource(client, uri)` — `resources/subscribe`
  - `unsubscribe_resource(client, uri)` — `resources/unsubscribe`
  - `list_prompts(client, opts \\ [])` — `prompts/list` request
  - `get_prompt(client, name, arguments \\ %{})` — `prompts/get` request
  - `ping(client)` — `ping` request (should work even during initialization)
  - `close(client)` — graceful shutdown (close transport)
  - All operations: GenServer.call with configurable timeout

- [ ] **3.5** Implement pagination helper
  - `list_all_tools/2`, `list_all_resources/2`, `list_all_prompts/2`
  - Uses `Stream.resource/3` to lazily paginate with `cursor`/`nextCursor`
  - Each step sends a list request with the cursor from the previous response
  - Terminates when `nextCursor` is nil

- [ ] **3.6** Implement notification handling
  - Client receives notifications from server:
    - `notifications/tools/list_changed` — tools changed, should re-list
    - `notifications/resources/list_changed` — resources changed
    - `notifications/resources/updated` — specific resource updated (params: uri)
    - `notifications/prompts/list_changed` — prompts changed
    - `notifications/message` — log message from server
    - `notifications/progress` — progress update for a request
    - `notifications/cancelled` — server cancelled a request
  - Default: log unknown notifications
  - User can provide custom handler function/pid at connect time

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

- [ ] **4.1** Define server handler behaviour (`lib/mcp/server/handler.ex`)
  - `MCP.Server.Handler` behaviour — callbacks for all server features:
    - `init(opts) :: {:ok, handler_state}` — initialize handler state
    - `handle_list_tools(cursor, state) :: {:ok, tools, next_cursor, state}` — return tool list
    - `handle_call_tool(name, arguments, state) :: {:ok, result, state} | {:error, error, state}` — execute tool
    - `handle_list_resources(cursor, state) :: {:ok, resources, next_cursor, state}`
    - `handle_read_resource(uri, state) :: {:ok, contents, state} | {:error, error, state}`
    - `handle_subscribe(uri, state) :: {:ok, state} | {:error, error, state}`
    - `handle_unsubscribe(uri, state) :: {:ok, state} | {:error, error, state}`
    - `handle_list_resource_templates(cursor, state) :: {:ok, templates, next_cursor, state}`
    - `handle_list_prompts(cursor, state) :: {:ok, prompts, next_cursor, state}`
    - `handle_get_prompt(name, arguments, state) :: {:ok, result, state} | {:error, error, state}`
    - `handle_complete(ref, argument, state) :: {:ok, result, state}`
    - `handle_set_log_level(level, state) :: {:ok, state}`
  - All callbacks optional (use `@optional_callbacks`) — server only advertises capabilities for implemented handlers
  - Default implementations return "method not found" errors

- [ ] **4.2** Implement server GenServer (`lib/mcp/server.ex`)
  - `MCP.Server` — GenServer managing transport + handler dispatch
  - State:
    - `handler_module` + `handler_state` — the user's Handler implementation
    - `transport_module` / `transport_pid` — transport process
    - `client_capabilities` — from client's initialize request
    - `client_info` — client's Implementation struct
    - `server_info` — our Implementation struct (name, version)
    - `capabilities` — our ServerCapabilities (derived from handler module)
    - `session_id` — generated for Streamable HTTP, nil for stdio
    - `status` — `:waiting | :initializing | :ready | :closed`
    - `pending_requests` — for server-initiated requests (sampling, elicitation)
    - `next_id` — incrementing integer for server-initiated request IDs
  - Auto-detect capabilities: inspect handler module's exported functions to determine which capabilities to advertise

- [ ] **4.3** Implement initialization handshake (server side)
  - Receive `initialize` request from client
  - Validate protocol version (must be "2025-11-25" or negotiate)
  - Respond with server capabilities + server info + instructions
  - Wait for `initialized` notification before processing other requests
  - Reject non-ping requests before initialization completes

- [ ] **4.4** Implement request routing (`lib/mcp/server/router.ex`)
  - `MCP.Server.Router` — routes JSON-RPC method strings to handler callbacks:
    - `"initialize"` → built-in initialization logic
    - `"ping"` → built-in empty response
    - `"tools/list"` → `handler.handle_list_tools/2`
    - `"tools/call"` → `handler.handle_call_tool/3`
    - `"resources/list"` → `handler.handle_list_resources/2`
    - `"resources/read"` → `handler.handle_read_resource/2`
    - `"resources/subscribe"` → `handler.handle_subscribe/2`
    - `"resources/unsubscribe"` → `handler.handle_unsubscribe/2`
    - `"resources/templates/list"` → `handler.handle_list_resource_templates/2`
    - `"prompts/list"` → `handler.handle_list_prompts/2`
    - `"prompts/get"` → `handler.handle_get_prompt/3`
    - `"completion/complete"` → `handler.handle_complete/3`
    - `"logging/setLevel"` → `handler.handle_set_log_level/2`
    - Unknown method → error response (-32601)
  - Check capabilities before dispatching (e.g., reject tools/call if tools not declared)

- [ ] **4.5** Implement server-initiated messages
  - `MCP.Server.notify_tools_changed/1` — send `notifications/tools/list_changed`
  - `MCP.Server.notify_resources_changed/1` — send `notifications/resources/list_changed`
  - `MCP.Server.notify_resource_updated/2` — send `notifications/resources/updated` (with uri)
  - `MCP.Server.notify_prompts_changed/1` — send `notifications/prompts/list_changed`
  - `MCP.Server.log/3` — send `notifications/message` (level, logger, data)
  - `MCP.Server.send_progress/3` — send `notifications/progress` (progressToken, progress, total)
  - `MCP.Server.request_sampling/2` — send `sampling/createMessage` request to client (if client has sampling capability)
  - `MCP.Server.request_roots/1` — send `roots/list` request to client (if client has roots capability)
  - `MCP.Server.request_elicitation/2` — send `elicitation/create` request to client (if client has elicitation capability)

- [ ] **4.6** Implement simple handler helpers
  - `MCP.Server.SimpleHandler` — a convenience module that stores tools/resources/prompts in state
  - Accepts tool/resource/prompt definitions at startup via `init/1` opts
  - Tools: name → handler function mapping
  - Resources: uri → content mapping (static or function-backed)
  - Prompts: name → template mapping
  - This provides a quick way to build a server without implementing the full Handler behaviour

- [ ] **4.7** Implement server run modes
  - `MCP.Server.run/2` — blocking mode for stdio (reads until EOF)
  - `MCP.Server.start_link/1` — supervised mode (for HTTP transport or long-lived stdio)
  - Stdio server: read from stdin, write to stdout (no subprocess — we ARE the subprocess)

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

- [ ] **5.1** Add optional HTTP dependencies
  - `{:req, "~> 0.5", optional: true}` — HTTP client (for client-side Streamable HTTP)
  - `{:plug, "~> 1.16", optional: true}` — HTTP framework (for server-side Streamable HTTP)
  - `{:bandit, "~> 1.5", optional: true}` — HTTP server (for server-side Streamable HTTP)
  - `{:plug_cowboy, "~> 2.7", optional: true}` — alternative HTTP server
  - Ensure stdio transport works with zero HTTP deps

- [ ] **5.2** Implement Streamable HTTP client transport (`lib/mcp/transport/streamable_http/client.ex`)
  - `MCP.Transport.StreamableHTTP.Client` — GenServer implementing Transport behaviour
  - Sends JSON-RPC messages via HTTP POST to server endpoint
  - Required headers:
    - `Content-Type: application/json`
    - `Accept: application/json, text/event-stream`
    - `MCP-Protocol-Version: 2025-11-25`
    - `MCP-Session-Id: <session_id>` (after initialization)
  - Response handling:
    - `application/json` → single JSON-RPC response, deliver to owner
    - `text/event-stream` → SSE stream, parse events, deliver each as message to owner
  - SSE parsing:
    - Lines starting with `data: ` contain JSON-RPC messages
    - Lines starting with `id: ` set the last event ID (for resumability)
    - Lines starting with `event: ` set event type (usually "message")
    - Empty line = end of event
  - Session management:
    - Extract `MCP-Session-Id` from initialize response header
    - Include it in all subsequent requests
  - Optional: GET request for SSE stream (server-initiated messages)
    - Open persistent SSE connection for receiving server pushes
    - Include `Last-Event-ID` header for resumability
  - Connection lifecycle:
    - On close: send HTTP DELETE to session endpoint (if session ID exists)

- [ ] **5.3** Implement Streamable HTTP server transport (`lib/mcp/transport/streamable_http/server.ex`)
  - `MCP.Transport.StreamableHTTP.Server` — Plug implementing server-side transport
  - POST endpoint:
    - Receive JSON-RPC message from request body
    - Check `MCP-Protocol-Version` header (must be "2025-11-25")
    - Check `MCP-Session-Id` header (must match if stateful session)
    - Route message to server GenServer for processing
    - Response options:
      a. Single JSON response: `Content-Type: application/json`
      b. SSE stream: `Content-Type: text/event-stream`, send server messages then final response
    - For initialize: generate session ID, include in response header
  - GET endpoint (optional):
    - Open SSE stream for server-initiated messages
    - Client connects, receives push notifications/requests
    - Uses chunked transfer encoding
  - DELETE endpoint:
    - Client requests session termination
    - Clean up server session state
  - Session registry:
    - Map session IDs to server GenServer pids
    - Session timeout / cleanup for abandoned sessions

- [ ] **5.4** Implement SSE parsing/encoding utilities (`lib/mcp/transport/sse.ex`)
  - `MCP.Transport.SSE.encode/2` — encode a JSON-RPC message as SSE event
    - Format: `event: message\ndata: <json>\nid: <optional_id>\n\n`
  - `MCP.Transport.SSE.decode/1` — parse SSE event text into components
  - `MCP.Transport.SSE.stream_parser/0` — stateful parser for chunked SSE data
    - Handles partial reads, buffers incomplete events
    - Emits complete events as they arrive

- [ ] **5.5** Integration testing (client ↔ server over HTTP)
  - Start Bandit server with our Plug
  - Connect MCP.Client with Streamable HTTP transport
  - Full lifecycle: initialize → tools/list → tools/call → close
  - Test SSE streaming responses
  - Test session management (MCP-Session-Id)
  - Test resumability (Last-Event-ID)
  - Test server-initiated messages via GET SSE stream

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

- [ ] **6.1** Implement sampling client feature
  - Client advertises `sampling` capability during initialization
  - When server sends `sampling/createMessage` request:
    - Client dispatches to `on_sampling` callback provided at connect time
    - Callback receives CreateMessageParams (messages, modelPreferences, systemPrompt, maxTokens, tools, toolChoice, metadata)
    - Callback returns CreateMessageResult (role, content, model, stopReason)
    - If tools included in sampling request: client may need to handle multi-turn tool loop
  - If no callback registered: respond with error (-1, user rejected)

- [ ] **6.2** Implement roots client feature
  - Client advertises `roots` capability during initialization
  - When server sends `roots/list` request:
    - Client dispatches to `on_roots_list` callback
    - Callback returns list of `%{uri: "file:///...", name: "project"}` roots
  - Client can send `notifications/roots/list_changed` to server when roots change
  - `MCP.Client.notify_roots_changed/1` API

- [ ] **6.3** Implement elicitation client feature
  - Client advertises `elicitation` capability during initialization (form and/or URL modes)
  - When server sends `elicitation/create` request:
    - Client dispatches to `on_elicitation` callback
    - Params: message (string), requestedSchema (JSON Schema for form), title
    - Callback returns: %{action: "accept"|"decline"|"cancel", content: %{...}}
  - URL elicitation:
    - Server returns error -32042 (URL elicitation required) with url and description in data
    - Client opens URL, waits for completion notification
    - Completion notification: `notifications/elicitation/url/completed` with elicitationId

- [ ] **6.4** Implement progress notifications
  - Client sends `notifications/progress` with progressToken, progress, total, message
  - Server sends progress notifications for long-running operations
  - Both sides: match progressToken to the original request's _meta.progressToken

- [ ] **6.5** Implement request cancellation
  - `notifications/cancelled` — either side can cancel a pending request
  - Client: `MCP.Client.cancel/2` — send cancellation notification for a request ID
  - Server: handle incoming cancellation, abort in-progress handler if possible
  - Params: requestId, reason (optional string)

- [ ] **6.6** Build conformance test adapter scripts
  - **Server adapter**: Elixir script that starts our MCP server on stdio
    - Registers test tools, resources, prompts expected by conformance suite
    - Runs as: `elixir server_adapter.exs` (or escript)
  - **Client adapter**: Elixir script that runs our MCP client
    - Connects to conformance test server via stdio
    - Exercises operations as directed
  - Place in `conformance/` directory with instructions

- [ ] **6.7** Run conformance test suite
  - `npx @modelcontextprotocol/conformance test --server "elixir conformance/server_adapter.exs"`
  - `npx @modelcontextprotocol/conformance test --client "elixir conformance/client_adapter.exs"`
  - Create `conformance/expected_failures.json` baseline file
  - Document pass rate and known failures
  - Target: 80%+ (Tier 2 minimum)

- [ ] **6.8** Integration tests: client ↔ server in-process
  - Full lifecycle with stdio transport connecting our client to our server
  - Test all server features: tools, resources, prompts, subscriptions, logging
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
| Phase 1: Core Protocol | ~40 | 40 |
| Phase 2: Transport + Stdio | ~20 | 60 |
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
