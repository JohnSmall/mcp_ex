# Simple echo server for stdio transport testing.
#
# Reads newline-delimited JSON from stdin.
# For each valid JSON-RPC request, responds with a result containing
# the original params. For notifications, does nothing.
# Special method "exit" causes the server to shut down.
#
# Usage: mix run test/support/echo_server.exs

defmodule EchoServer do
  def run do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        line = String.trim(line)

        if line != "" do
          handle_line(line)
        end

        run()
    end
  end

  defp handle_line(line) do
    case Jason.decode(line) do
      {:ok, %{"method" => "exit"}} ->
        System.halt(0)

      {:ok, %{"id" => id, "method" => _method, "params" => params}} ->
        response = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"echo" => params}
        }

        IO.write(:stdio, Jason.encode!(response) <> "\n")

      {:ok, %{"id" => id, "method" => _method}} ->
        response = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"echo" => %{}}
        }

        IO.write(:stdio, Jason.encode!(response) <> "\n")

      {:ok, %{"method" => _}} ->
        # Notification — no response
        :ok

      {:error, _} ->
        error_response = %{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32_700, "message" => "Parse error"}
        }

        IO.write(:stdio, Jason.encode!(error_response) <> "\n")
    end
  end
end

EchoServer.run()
