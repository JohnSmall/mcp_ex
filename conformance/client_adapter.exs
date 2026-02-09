#!/usr/bin/env elixir
# MCP Conformance Client Adapter
#
# Connects to a conformance test server and executes the specified scenario.
#
# Usage:
#   mix run conformance/client_adapter.exs <server_url>
#
# Environment variables:
#   MCP_CONFORMANCE_SCENARIO - scenario to execute (e.g., "initialize", "tools-call")
#   MCP_CONFORMANCE_CONTEXT  - optional JSON context for the scenario

defmodule MCP.Conformance.ClientAdapter do
  alias MCP.Client

  def run do
    server_url = List.last(System.argv()) || raise "Server URL required as last argument"
    scenario = System.get_env("MCP_CONFORMANCE_SCENARIO") || "initialize"

    IO.puts("Scenario: #{scenario}")
    IO.puts("Server URL: #{server_url}")

    run_scenario(scenario, server_url)
    IO.puts("Scenario '#{scenario}' completed successfully")
  end

  defp run_scenario("initialize", url) do
    {:ok, client} = start_client(url)
    {:ok, _result} = Client.connect(client)
    Client.close(client)
  end

  defp run_scenario("tools-call", url) do
    {:ok, client} = start_client(url)
    {:ok, _result} = Client.connect(client)
    {:ok, _tools} = Client.list_tools(client)
    {:ok, _result} = Client.call_tool(client, "test_simple_text", %{})
    Client.close(client)
  end

  defp run_scenario(scenario, _url) do
    IO.puts("Unknown scenario: #{scenario}")
    System.halt(1)
  end

  defp start_client(url) do
    Client.start_link(
      transport:
        {MCP.Transport.StreamableHTTP.Client, url: url, headers: []},
      client_info: %{name: "mcp_ex_conformance", version: "0.1.0"},
      on_sampling: fn params ->
        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "Conformance test response"},
           "model" => "conformance-test",
           "stopReason" => "endTurn"
         }}
      end,
      on_roots_list: fn _params ->
        {:ok, %{"roots" => [%{"uri" => "file:///conformance", "name" => "conformance"}]}}
      end,
      on_elicitation: fn params ->
        {:ok, %{"action" => "accept", "content" => %{"username" => "test", "email" => "test@test.com"}}}
      end
    )
  end
end

MCP.Conformance.ClientAdapter.run()
