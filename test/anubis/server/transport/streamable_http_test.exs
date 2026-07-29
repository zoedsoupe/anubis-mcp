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

    test "a superseded handler is not proactively closed", %{transport: transport} do
      session_id = "test-session-supersede"
      test_pid = self()

      old_handler =
        spawn(fn ->
          :ok = StreamableHTTP.register_sse_handler(transport, session_id)
          send(test_pid, {:registered, self()})

          receive do
            :close_sse -> send(test_pid, {:closed, self()})
          end
        end)

      assert_receive {:registered, ^old_handler}

      # A second connection takes over the same session.
      new_handler =
        spawn(fn ->
          :ok = StreamableHTTP.register_sse_handler(transport, session_id)
          send(test_pid, {:registered, self()})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:registered, ^new_handler}

      # The new handler becomes the active one for the session...
      assert ^new_handler = StreamableHTTP.get_sse_handler(transport, session_id)

      # ...and the superseded handler is NOT sent :close_sse. A server-initiated
      # close would make a spec-compliant client immediately reconnect, racing
      # the next registration into an unbounded register/close flap.
      refute_receive {:closed, ^old_handler}, 200

      send(old_handler, :close_sse)
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

    test "send_message with session_id routes to that session only", %{transport: transport} do
      session_a = "session-a-#{System.unique_integer([:positive])}"
      session_b = "session-b-#{System.unique_integer([:positive])}"
      test_pid = self()

      pid_a =
        spawn(fn ->
          :ok = StreamableHTTP.register_sse_handler(transport, session_a)
          send(test_pid, {:handler_ready, :a})

          receive do
            {:sse_message, msg} -> send(test_pid, {:got, :a, msg})
          end
        end)

      pid_b =
        spawn(fn ->
          :ok = StreamableHTTP.register_sse_handler(transport, session_b)
          send(test_pid, {:handler_ready, :b})

          receive do
            {:sse_message, msg} -> send(test_pid, {:got, :b, msg})
          end
        end)

      assert_receive {:handler_ready, :a}
      assert_receive {:handler_ready, :b}

      message = "session-scoped message"

      assert :ok =
               StreamableHTTP.send_message(transport, message,
                 timeout: 5000,
                 session_id: session_a
               )

      assert_receive {:got, :a, ^message}
      refute_receive {:got, :b, _}, 200

      StreamableHTTP.unregister_sse_handler(transport, session_a, pid_a)
      StreamableHTTP.unregister_sse_handler(transport, session_b, pid_b)
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

  describe "cross-node SSE routing" do
    # A full multi-node test would need :slave/:peer node orchestration, which
    # is impractical here. Instead we exercise the routing seam directly: the
    # transport discovers handlers through a :pg group keyed by session id, so
    # joining a pid to that group from the test faithfully simulates a handler
    # registered with a sibling node's transport.
    setup do
      name = Registry.transport_name(StubServer, :streamable_http)
      sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: sup})

      {:ok, transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, task_supervisor: sup})

      %{transport: transport, pg_scope: :"#{name}.sse_pg"}
    end

    test "route_to_session delivers to a handler registered on another node", %{
      transport: transport,
      pg_scope: pg_scope
    } do
      session_id = "remote-session-#{System.unique_integer([:positive])}"
      test_pid = self()

      refute StreamableHTTP.get_sse_handler(transport, session_id)

      spawn(fn ->
        :pg.join(pg_scope, session_id, self())
        send(test_pid, :joined)

        receive do
          {:sse_message, message} -> send(test_pid, {:delivered, message})
        end
      end)

      assert_receive :joined

      assert :ok = StreamableHTTP.route_to_session(transport, session_id, "cluster message")
      assert_receive {:delivered, "cluster message"}
    end

    test "route_to_session returns no_sse_handler when no handler exists anywhere", %{transport: transport} do
      session_id = "ghost-session-#{System.unique_integer([:positive])}"

      assert {:error, :no_sse_handler} = StreamableHTTP.route_to_session(transport, session_id, "lost")
    end

    test "local registration joins the shared :pg group", %{transport: transport, pg_scope: pg_scope} do
      session_id = "local-session-#{System.unique_integer([:positive])}"

      assert :ok = StreamableHTTP.register_sse_handler(transport, session_id)
      assert self() in :pg.get_members(pg_scope, session_id)
    end

    test "unregistering a local handler leaves the :pg group", %{transport: transport, pg_scope: pg_scope} do
      session_id = "leaving-session-#{System.unique_integer([:positive])}"
      test_pid = self()

      handler =
        spawn(fn ->
          :ok = StreamableHTTP.register_sse_handler(transport, session_id)
          send(test_pid, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered
      assert handler in :pg.get_members(pg_scope, session_id)

      :ok = StreamableHTTP.unregister_sse_handler(transport, session_id, handler)

      assert eventually(fn -> :pg.get_members(pg_scope, session_id) == [] end)
    end

    test "a superseded handler leaves the :pg group", %{transport: transport, pg_scope: pg_scope} do
      session_id = "supersede-session-#{System.unique_integer([:positive])}"
      test_pid = self()

      old_handler =
        spawn(fn ->
          :ok = StreamableHTTP.register_sse_handler(transport, session_id)
          send(test_pid, {:registered, :old})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:registered, :old}

      new_handler =
        spawn(fn ->
          :ok = StreamableHTTP.register_sse_handler(transport, session_id)
          send(test_pid, {:registered, :new})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:registered, :new}

      members = :pg.get_members(pg_scope, session_id)
      assert new_handler in members
      refute old_handler in members

      send(old_handler, :stop)
      send(new_handler, :stop)
    end

    test "a dead handler is removed from the :pg group by :pg itself", %{
      transport: transport,
      pg_scope: pg_scope
    } do
      session_id = "dying-session-#{System.unique_integer([:positive])}"
      test_pid = self()

      handler =
        spawn(fn ->
          :ok = StreamableHTTP.register_sse_handler(transport, session_id)
          send(test_pid, :registered)
        end)

      assert_receive :registered
      refute Process.alive?(handler)

      assert eventually(fn -> :pg.get_members(pg_scope, session_id) == [] end)
    end
  end

  # Retries `fun` with a linear backoff, returning true as soon as it holds.
  defp eventually(fun) do
    Enum.reduce_while(1..5, nil, fn attempt, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(attempt * 10)
        {:cont, nil}
      end
    end) || raise "condition never became true after 5 attempts"
  end
end
