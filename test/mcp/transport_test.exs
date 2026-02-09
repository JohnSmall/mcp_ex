defmodule MCP.TransportTest do
  use ExUnit.Case, async: true

  alias MCP.Test.MockTransport

  describe "MockTransport" do
    test "sends and collects messages" do
      {:ok, transport} = MockTransport.start_link(owner: self())

      assert :ok =
               MockTransport.send_message(transport, %{"jsonrpc" => "2.0", "method" => "ping"})

      assert :ok =
               MockTransport.send_message(transport, %{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "tools/list"
               })

      messages = MockTransport.sent_messages(transport)
      assert length(messages) == 2
      assert Enum.at(messages, 0)["method"] == "ping"
      assert Enum.at(messages, 1)["id"] == 1
    end

    test "last_sent/1 returns the most recent message" do
      {:ok, transport} = MockTransport.start_link(owner: self())

      assert MockTransport.last_sent(transport) == nil

      MockTransport.send_message(transport, %{"first" => true})
      MockTransport.send_message(transport, %{"second" => true})

      assert MockTransport.last_sent(transport)["second"] == true
    end

    test "inject/2 delivers message to owner" do
      {:ok, transport} = MockTransport.start_link(owner: self())

      message = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}}
      MockTransport.inject(transport, message)

      assert_receive {:mcp_message, ^message}
    end

    test "close/1 sends transport_closed to owner" do
      {:ok, transport} = MockTransport.start_link(owner: self())

      assert :ok = MockTransport.close(transport)
      assert_receive {:mcp_transport_closed, :normal}
      assert MockTransport.closed?(transport) == true
    end
  end
end
