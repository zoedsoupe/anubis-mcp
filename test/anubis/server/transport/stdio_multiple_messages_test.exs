defmodule Anubis.Server.Transport.StdioMultipleMessagesTest do
  use ExUnit.Case
  alias Anubis.MCP.Message

  describe "Message.decode/1 with multiple messages" do
    test "decodes multiple JSON-RPC messages in a single input" do
      # Simulate multiple JSON-RPC messages as they might come from STDIO
      # Using valid MCP protocol messages
      input = """
      {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}
      {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
      """

      # This should return a list of messages, not crash
      assert {:ok, messages} = Message.decode(input)
      assert is_list(messages)
      assert length(messages) == 2

      # Verify first message
      [first, second] = messages
      assert first["method"] == "initialize"
      assert first["id"] == 1

      # Verify second message
      assert second["method"] == "tools/list"
      assert second["id"] == 2
    end

    test "handles single message" do
      input = ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}})

      assert {:ok, result} = Message.decode(input)

      # Result should be a list with one message
      assert is_list(result)
      assert length(result) == 1

      [message] = result
      assert message["method"] == "initialize"
      assert message["id"] == 1
    end

    test "handles empty lines between messages" do
      input = """
      {"jsonrpc":"2.0","id":1,"method":"ping","params":{}}

      {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
      """

      assert {:ok, messages} = Message.decode(input)
      assert is_list(messages)
      # Empty lines are filtered out, so we get 2 messages
      assert length(messages) == 2
    end
  end
end