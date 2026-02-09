#!/usr/bin/env elixir
# MCP Conformance Server Adapter
#
# Starts an MCP server over Streamable HTTP for conformance testing.
#
# Usage:
#   mix run conformance/server_adapter.exs [port]
#
# Then run conformance tests:
#   npx @modelcontextprotocol/conformance server --url http://localhost:<port>/mcp
#
# Default port: 3001

# Load the handler module
Code.require_file("server_handler.ex", Path.dirname(__ENV__.file))

port =
  case System.argv() do
    [port_str | _] -> String.to_integer(port_str)
    _ -> 3001
  end

plug =
  MCP.Transport.StreamableHTTP.Plug.new(
    server_mod: MCP.Conformance.ServerHandler,
    server_opts: [],
    enable_json_response: false,
    protocol_version: "2025-11-25"
  )

IO.puts("Starting MCP Conformance Server on http://localhost:#{port}/mcp")

{:ok, _} = Bandit.start_link(plug: plug, port: port, ip: {127, 0, 0, 1})

IO.puts("Server ready. Press Ctrl+C to stop.")

# Block forever
Process.sleep(:infinity)
