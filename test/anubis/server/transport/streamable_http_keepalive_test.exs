defmodule Anubis.Server.Transport.StreamableHTTPKeepaliveTest do
  @moduledoc """
  Tests for SSE keepalive functionality in StreamableHTTP transport.

  This test suite reproduces and verifies the fix for the bug where SSE keepalive
  messages are not sent when SSE handlers are registered after server startup.
  """

  use Anubis.MCP.Case, async: false

  import ExUnit.CaptureLog

  alias Anubis.Server.Transport.StreamableHTTP

  setup :with_default_registry

  describe "SSE keepalive" do
    setup do
      registry = Anubis.Server.Registry
      name = registry.transport(StubServer, :streamable_http)
      sup = registry.task_supervisor(StubServer)
      start_supervised!({Task.Supervisor, name: sup})

      # Start transport with keepalive enabled and short interval for testing
      {:ok, transport} =
        start_supervised({StreamableHTTP,
          server: StubServer,
          name: name,
          registry: registry,
          task_supervisor: sup,
          keepalive: true,
          keepalive_interval: 100
        })

      %{transport: transport, server: StubServer}
    end

    test "sends keepalive messages when SSE handler is registered", %{transport: transport} do
      session_id = "test-keepalive-session"

      # Register SSE handler
      assert :ok = StreamableHTTP.register_sse_handler(transport, session_id)

      # Should receive at least one keepalive message
      assert_receive :sse_keepalive, 300

      # Clean up
      capture_log(fn ->
        StreamableHTTP.unregister_sse_handler(transport, session_id)
        Process.sleep(10)
      end)
    end

    test "continues sending keepalive when multiple handlers exist", %{transport: transport} do
      session_id1 = "test-keepalive-1"
      session_id2 = "test-keepalive-2"

      # Register first handler
      assert :ok = StreamableHTTP.register_sse_handler(transport, session_id1)

      # Clear mailbox
      flush_mailbox()

      # Verify keepalive is received
      assert_receive :sse_keepalive, 200

      # Register second handler
      assert :ok = StreamableHTTP.register_sse_handler(transport, session_id2)

      # Clear mailbox again
      flush_mailbox()

      # Verify keepalive still works
      assert_receive :sse_keepalive, 200

      # Clean up
      capture_log(fn ->
        StreamableHTTP.unregister_sse_handler(transport, session_id1)
        StreamableHTTP.unregister_sse_handler(transport, session_id2)
        Process.sleep(10)
      end)
    end

    test "stops sending keepalive when all handlers are unregistered", %{transport: transport} do
      session_id = "test-keepalive-stop"

      # Register and then unregister handler
      assert :ok = StreamableHTTP.register_sse_handler(transport, session_id)
      assert_receive :sse_keepalive, 200

      # Unregister
      capture_log(fn ->
        StreamableHTTP.unregister_sse_handler(transport, session_id)
        Process.sleep(10)
      end)

      # Clear mailbox
      flush_mailbox()

      # Wait longer than keepalive interval
      Process.sleep(250)

      # Should not receive keepalive after all handlers removed
      refute_received :sse_keepalive
    end

    test "starts keepalive immediately when first handler registered after startup", %{
      transport: transport
    } do
      # This is the critical test case that fails without the fix
      # When server starts with no SSE handlers, keepalive is not scheduled
      # Then when first handler is registered, keepalive must start

      session_id = "test-first-handler"

      # Ensure no handlers exist initially (server starts empty)
      # Register first handler
      assert :ok = StreamableHTTP.register_sse_handler(transport, session_id)

      # WITHOUT FIX: This would fail because keepalive was never scheduled
      # WITH FIX: This succeeds because register_sse_handler triggers keepalive
      assert_receive :sse_keepalive, 200

      # Clean up
      capture_log(fn ->
        StreamableHTTP.unregister_sse_handler(transport, session_id)
        Process.sleep(10)
      end)
    end
  end

  # Recursively flushes all messages from the process mailbox.
  # This helper is used to clear any accumulated keepalive messages before
  # verifying new ones are received.
  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
