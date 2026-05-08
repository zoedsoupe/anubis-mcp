defmodule Anubis.Server.SessionAsyncDispatchTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.MCP.Message
  alias Anubis.Server.Registry
  alias Anubis.Server.Session
  alias Anubis.Test.SyncHelpers

  @moduletag capture_log: true

  setup :start_async_session

  describe "mailbox unblock" do
    test "cancellation aborts in-flight tool task and replies", %{session: session} do
      caller = self()
      ctx = with_test_pid()

      Task.start(fn ->
        request = tool_call_request("wait_signal", %{"signal" => "alpha"}, "req-1")
        result = GenServer.call(session, {:mcp_request, request, ctx}, 5_000)
        send(caller, {:tool_reply, result})
      end)

      assert_receive {:tool_running, tool_pid, :alpha}, 1_000
      assert Process.alive?(tool_pid)

      cancellation = cancelled_notification("req-1", "user requested abort")
      :ok = GenServer.cast(session, {:mcp_notification, cancellation, ctx})

      assert_receive {:tool_reply, {:ok, encoded}}, 500
      decoded = decode_one(encoded)
      assert decoded["error"]["message"] == "Request cancelled"
      assert decoded["error"]["data"]["reason"] == "user requested abort"

      ref = Process.monitor(tool_pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 500
    end
  end

  describe "FIFO ordering of queued requests" do
    test "queued requests reply in arrival order and observe accumulated frame state", %{session: session} do
      caller = self()
      ctx = with_test_pid()

      Task.start(fn ->
        req = tool_call_request("wait_signal", %{"signal" => "first"}, "id-1")
        send(caller, {:reply, 1, GenServer.call(session, {:mcp_request, req, ctx}, 5_000)})
      end)

      assert_receive {:tool_running, blocker_pid, :first}, 1_000

      for n <- 2..4 do
        Task.start(fn ->
          req = tool_call_request("increment", %{}, "id-#{n}")
          send(caller, {:reply, n, GenServer.call(session, {:mcp_request, req, ctx}, 5_000)})
        end)
      end

      SyncHelpers.await_state(session, &(:queue.len(&1.request_queue) == 3))

      send(blocker_pid, {:proceed, :first})

      assert_receive {:reply, 1, {:ok, _}}, 1_000
      assert_receive {:reply, 2, {:ok, e2}}, 1_000
      assert_receive {:reply, 3, {:ok, e3}}, 1_000
      assert_receive {:reply, 4, {:ok, e4}}, 1_000

      assert tool_text(e2) == "count=1"
      assert tool_text(e3) == "count=2"
      assert tool_text(e4) == "count=3"
    end
  end

  describe "crash isolation" do
    test "tool crash returns internal_error and session keeps serving", %{session: session} do
      caller = self()
      ctx = with_test_pid()

      Task.start(fn ->
        req = tool_call_request("crash", %{}, "boom-1")
        send(caller, {:reply, GenServer.call(session, {:mcp_request, req, ctx}, 5_000)})
      end)

      assert_receive {:reply, {:ok, encoded}}, 1_000
      decoded = decode_one(encoded)
      assert decoded["error"]["code"] == -32_603
      assert Process.alive?(session)

      followup = tool_call_request("echo", %{"value" => "alive"}, "ok-1")
      assert {:ok, encoded2} = GenServer.call(session, {:mcp_request, followup, ctx}, 5_000)
      assert tool_text(encoded2) == "alive"
    end

    test "malformed handler return becomes internal_error, session survives", %{session: session} do
      caller = self()
      ctx = with_test_pid()

      Task.start(fn ->
        req = tool_call_request("malformed_return", %{}, "bad-1")
        send(caller, {:reply, GenServer.call(session, {:mcp_request, req, ctx}, 5_000)})
      end)

      assert_receive {:reply, {:ok, encoded}}, 1_000
      decoded = decode_one(encoded)
      assert decoded["error"]["code"] == -32_603
      assert decoded["error"]["data"]["message"] == "Invalid handler return value"
      assert Process.alive?(session)

      followup = tool_call_request("echo", %{"value" => "still-alive"}, "ok-2")
      assert {:ok, encoded2} = GenServer.call(session, {:mcp_request, followup, ctx}, 5_000)
      assert tool_text(encoded2) == "still-alive"
    end
  end

  describe "cancel queued request" do
    test "queued request is removed and replied without executing", %{session: session} do
      caller = self()
      ctx = with_test_pid()

      Task.start(fn ->
        req = tool_call_request("wait_signal", %{"signal" => "blocker"}, "block-1")
        send(caller, {:reply, :blocker, GenServer.call(session, {:mcp_request, req, ctx}, 5_000)})
      end)

      assert_receive {:tool_running, blocker_pid, :blocker}, 1_000

      Task.start(fn ->
        req = tool_call_request("wait_signal", %{"signal" => "queued"}, "queued-1")
        send(caller, {:reply, :queued, GenServer.call(session, {:mcp_request, req, ctx}, 5_000)})
      end)

      SyncHelpers.await_state(session, &(:queue.len(&1.request_queue) == 1))

      cancellation = cancelled_notification("queued-1", "abort queued")
      :ok = GenServer.cast(session, {:mcp_notification, cancellation, ctx})

      assert_receive {:reply, :queued, {:ok, encoded}}, 500
      decoded = decode_one(encoded)
      assert decoded["error"]["data"]["reason"] == "abort queued"
      refute_received {:tool_running, _, :queued}

      send(blocker_pid, {:proceed, :blocker})
      assert_receive {:reply, :blocker, {:ok, _}}, 1_000
    end
  end

  describe "deferred competing frame writers" do
    test "sampling response is deferred until in-flight tool completes", %{session: session} do
      caller = self()
      ctx = with_test_pid()

      Task.start(fn ->
        req = tool_call_request("wait_signal", %{"signal" => "tool"}, "t-1")
        send(caller, {:reply, GenServer.call(session, {:mcp_request, req, ctx}, 5_000)})
      end)

      assert_receive {:tool_running, tool_pid, :tool}, 1_000

      :sys.replace_state(session, fn state ->
        timer_ref = Process.send_after(session, {:sampling_request_timeout, "samp-1"}, 30_000)

        put_in(state.server_requests["samp-1"], %{
          method: "sampling/createMessage",
          session_id: state.session_id,
          timer_ref: timer_ref
        })
      end)

      sampling_response = %{
        "id" => "samp-1",
        "result" => %{"role" => "assistant", "content" => %{"type" => "text", "text" => "ok"}}
      }

      :ok = GenServer.cast(session, {:mcp_response, sampling_response, %{}})

      SyncHelpers.await_state(session, &(:queue.len(&1.deferred_callbacks) == 1))
      refute_received {:sampling_handled, _, _, _}

      send(tool_pid, {:proceed, :tool})

      assert_receive {:reply, {:ok, _}}, 1_000
      assert_receive {:sampling_handled, "samp-1", %{"role" => "assistant"}, _}, 1_000
    end
  end

  describe "session terminate" do
    test "queued and in-flight requests get internal_error reply on shutdown", %{session: session, task_sup: task_sup} do
      caller = self()
      ctx = with_test_pid()

      Task.start(fn ->
        req = tool_call_request("wait_signal", %{"signal" => "blocker2"}, "term-block")
        send(caller, {:reply, :blocker, GenServer.call(session, {:mcp_request, req, ctx}, 5_000)})
      end)

      assert_receive {:tool_running, blocker_pid, :blocker2}, 1_000
      ref = Process.monitor(blocker_pid)

      Task.start(fn ->
        req = tool_call_request("wait_signal", %{"signal" => "queued2"}, "term-queued")
        send(caller, {:reply, :queued, GenServer.call(session, {:mcp_request, req, ctx}, 5_000)})
      end)

      SyncHelpers.await_state(session, &(:queue.len(&1.request_queue) == 1))

      :ok = GenServer.stop(session, :shutdown, 1_000)

      assert_receive {:reply, :blocker, {:ok, encoded_blocker}}, 1_000
      assert_receive {:reply, :queued, {:ok, encoded_queued}}, 1_000

      assert decode_one(encoded_blocker)["error"]["code"] == -32_603
      assert decode_one(encoded_queued)["error"]["code"] == -32_603

      # In-flight task pid was terminated, not left running on the per-server task_supervisor
      assert_receive {:DOWN, ^ref, :process, _, _}, 500
      refute blocker_pid in Task.Supervisor.children(task_sup)
    end
  end

  defp start_async_session(_ctx) do
    session_id = "async-#{System.unique_integer([:positive])}"
    transport_name = Registry.transport_name(AsyncDispatchTestServer, StubTransport)
    # StubTransport (not MockTransport) — captures outbound frames and exposes clear/1 for isolation
    transport = start_supervised!({StubTransport, name: transport_name}, id: {:transport, session_id})
    task_sup = Registry.task_supervisor_name(AsyncDispatchTestServer)

    if is_nil(Process.whereis(task_sup)) do
      start_supervised!({Task.Supervisor, name: task_sup}, id: {:tasksup, session_id})
    end

    session_name = Registry.session_name(AsyncDispatchTestServer, session_id)

    session =
      start_supervised!(
        {Session,
         session_id: session_id,
         server_module: AsyncDispatchTestServer,
         name: session_name,
         transport: [layer: StubTransport, name: transport_name],
         task_supervisor: task_sup},
        id: {:session, session_id}
      )

    request = init_request("2025-03-26", %{"name" => "TestClient", "version" => "1.0.0"}, %{"sampling" => %{}})
    {:ok, _} = GenServer.call(session, {:mcp_request, request, with_test_pid()})

    init_notif = build_notification("notifications/initialized", %{})
    :ok = GenServer.cast(session, {:mcp_notification, init_notif, with_test_pid()})

    SyncHelpers.await_state(session, & &1.initialized)
    StubTransport.clear(transport)

    %{session: session, transport: transport, session_id: session_id, task_sup: task_sup}
  end

  defp with_test_pid, do: %{assigns: %{test_pid: self()}}

  defp tool_call_request(name, args, id) do
    build_request("tools/call", %{"name" => name, "arguments" => args}, id)
  end

  defp decode_one(encoded) do
    {:ok, [decoded]} = Message.decode(encoded)
    decoded
  end

  defp tool_text(encoded) do
    decoded = decode_one(encoded)
    [%{"text" => text}] = decoded["result"]["content"]
    text
  end
end
