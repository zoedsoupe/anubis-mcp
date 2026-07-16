defmodule Anubis.Server.Transport.StreamableHTTPTest do
  use Anubis.MCP.Case, async: false

  import ExUnit.CaptureLog

  alias Anubis.Server.Registry
  alias Anubis.Server.Transport.StreamableHTTP

  @moduletag capture_log: true

  describe "start_link/1" do
    test "starts with valid options" do
      server = :"test_server_#{System.unique_integer([:positive])}"
      name = Registry.transport_name(server, :streamable_http)
      sup = Registry.task_supervisor_name(server)

      assert {:ok, pid} =
               StreamableHTTP.start_link(server: server, name: name, task_supervisor: sup)

      assert Process.alive?(pid)
    end

    test "requires server option" do
      assert_raise Peri.InvalidSchema, fn ->
        StreamableHTTP.start_link(name: :test)
      end
    end
  end

  describe "with running transport" do
    setup do
      name = Registry.transport_name(StubServer, :streamable_http)
      sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: sup})

      {:ok, transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, task_supervisor: sup})

      %{transport: transport, server: StubServer}
    end

    test "registers and unregisters SSE handlers", %{transport: transport} do
      session_id = "test-session-123"
      handler_pid = self()

      assert :ok = StreamableHTTP.register_sse_handler(transport, session_id)
      assert ^handler_pid = StreamableHTTP.get_sse_handler(transport, session_id)
      assert :ok = StreamableHTTP.unregister_sse_handler(transport, session_id)
      refute StreamableHTTP.get_sse_handler(transport, session_id)
    end

    test "emits telemetry when an SSE handler registers", %{transport: transport, server: server} do
      event = [:anubis_mcp, :transport, :sse_handler, :registered]
      handler_id = "test-sse-register-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      session_id = "test-session-telemetry"
      handler_pid = self()

      assert :ok = StreamableHTTP.register_sse_handler(transport, session_id)

      assert_receive {:telemetry_event, measurements, metadata}
      assert %{count: 1, system_time: system_time} = measurements
      assert is_integer(system_time)

      assert %{
               transport: :streamable_http,
               server: ^server,
               session_id: ^session_id,
               handler_pid: ^handler_pid,
               handler_count: 1
             } = metadata
    end

    test "stale unregister cannot remove a newer handler", %{transport: transport} do
      session_id = "test-session-race"
      test_pid = self()

      old_handler =
        spawn(fn ->
          :ok = StreamableHTTP.register_sse_handler(transport, session_id)
          send(test_pid, {:registered, self()})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:registered, ^old_handler}

      new_handler =
        spawn(fn ->
          :ok = StreamableHTTP.register_sse_handler(transport, session_id)
          send(test_pid, {:registered, self()})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:registered, ^new_handler}
      assert ^new_handler = StreamableHTTP.get_sse_handler(transport, session_id)

      # Simulate delayed close from old SSE connection.
      assert :ok = StreamableHTTP.unregister_sse_handler(transport, session_id, old_handler)
      assert ^new_handler = StreamableHTTP.get_sse_handler(transport, session_id)

      assert :ok = StreamableHTTP.unregister_sse_handler(transport, session_id, new_handler)
      refute StreamableHTTP.get_sse_handler(transport, session_id)

      send(old_handler, :stop)
      send(new_handler, :stop)
    end

    test "routes messages to sessions", %{transport: transport} do
      session_id = "test-session-789"

      assert :ok = StreamableHTTP.register_sse_handler(transport, session_id)

      message = "test message"
      assert :ok = StreamableHTTP.route_to_session(transport, session_id, message)

      assert_receive {:sse_message, ^message}

      capture_log(fn ->
        StreamableHTTP.unregister_sse_handler(transport, session_id)
        Process.sleep(10)
      end)
    end

    test "cleans up handlers when they crash", %{transport: transport} do
      session_id = "test-session-crash"
      test_pid = self()

      capture_log(fn ->
        handler_pid =
          spawn(fn ->
            StreamableHTTP.register_sse_handler(transport, session_id)
            send(test_pid, :registered)

            receive do
              :crash -> exit(:boom)
            end
          end)

        assert_receive :registered, 1000

        handler = StreamableHTTP.get_sse_handler(transport, session_id)
        assert is_pid(handler)

        send(handler_pid, :crash)
        Process.sleep(100)

        refute StreamableHTTP.get_sse_handler(transport, session_id)
      end)
    end

    test "send_message/3 works", %{transport: transport} do
      message = "test message"
      assert :ok = StreamableHTTP.send_message(transport, message, timeout: 5000)
    end

    test "register_sse_handler/3 stores opaque metadata and reports counts", %{transport: transport} do
      assert :ok = StreamableHTTP.register_sse_handler(transport, "s1", %{tenant: "acme", role: "admin"})
      assert :ok = StreamableHTTP.register_sse_handler(transport, "s2", %{tenant: "acme", role: "member"})
      assert :ok = StreamableHTTP.register_sse_handler(transport, "s3", %{tenant: "globex", role: "admin"})

      assert StreamableHTTP.handler_count(transport) == 3
      assert StreamableHTTP.handler_count(transport, &(&1[:tenant] == "acme")) == 2
      assert StreamableHTTP.handler_count(transport, &(&1[:role] == "admin")) == 2
      assert StreamableHTTP.handler_count(transport, fn _ -> false end) == 0
    end

    test "register_sse_handler/2 defaults to empty metadata", %{transport: transport} do
      assert :ok = StreamableHTTP.register_sse_handler(transport, "s-empty")

      assert StreamableHTTP.handler_count(transport) == 1
      assert StreamableHTTP.handler_count(transport, &(&1 == %{})) == 1
    end

    test "send_message_to_subscribers delivers only to matching handlers", %{transport: transport} do
      assert :ok = StreamableHTTP.register_sse_handler(transport, "match-1", %{group: "a"})
      assert :ok = StreamableHTTP.register_sse_handler(transport, "match-2", %{group: "a"})
      assert :ok = StreamableHTTP.register_sse_handler(transport, "nomatch", %{group: "b"})

      message = "hello group a"

      assert :ok =
               StreamableHTTP.send_message_to_subscribers(transport, &(&1[:group] == "a"), message)

      # Two matching subscribers (both handled by this process) each receive it;
      # the "b" subscriber must not.
      assert_receive {:sse_message, ^message}
      assert_receive {:sse_message, ^message}
      refute_receive {:sse_message, _}, 50
    end

    test "shutdown/1 gracefully shuts down", %{transport: transport} do
      assert Process.alive?(transport)
      assert :ok = StreamableHTTP.shutdown(transport)
      Process.sleep(100)
      refute Process.alive?(transport)
    end
  end

  describe "supported_protocol_versions/0" do
    test "returns supported versions" do
      versions = StreamableHTTP.supported_protocol_versions()
      assert is_list(versions)
      assert "2025-03-26" in versions
    end
  end
end
