defmodule Anubis.Server.TasksTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.MCP.Message
  alias Anubis.Server.Registry
  alias Anubis.Server.Session
  alias Anubis.Server.TaskStore.Local, as: TaskStoreLocal
  alias Anubis.Test.SyncHelpers

  require Message

  @moduletag capture_log: true

  setup :start_tasks_session

  describe "task-augmented tools/call" do
    test "returns CreateTaskResult with strong-random taskId and related-task meta", %{session: session} do
      decoded =
        create_task_call(session, "wait_signal_add", %{"a" => 1, "b" => 2, "signal" => "alpha"}, "req-1", ttl: 30_000)

      task = decoded["result"]["task"]
      assert is_binary(task["taskId"])
      # Base64url(16 random bytes) decodes back to 16 bytes of entropy.
      decoded_id = Base.url_decode64!(task["taskId"], padding: false)
      assert byte_size(decoded_id) == 16
      assert task["status"] == "working"
      assert task["ttl"] == 30_000
      assert task["createdAt"] =~ ~r/\d{4}-\d{2}-\d{2}T/

      assert decoded["result"]["_meta"]["io.modelcontextprotocol/related-task"]["taskId"] == task["taskId"]

      # Worker is in flight — release it for cleanup.
      assert_receive {:tool_running, pid, :alpha}, 500
      send(pid, {:proceed, :alpha})
    end

    test "rejects forbidden tool with -32601", %{session: session} do
      decoded = call_session(session, build_request_with_task("no_tasks", %{}, "req-1"))
      assert decoded["error"]["code"] == -32_601
    end

    test "rejects required tool when called without task", %{session: session} do
      decoded =
        call_session(
          session,
          build_request("tools/call", %{"name" => "must_be_task", "arguments" => %{"msg" => "hi"}}, "req-1")
        )

      assert decoded["error"]["code"] == -32_601
    end
  end

  describe "tasks/get" do
    test "returns 'completed' once worker finishes", %{session: session} do
      create =
        create_task_call(session, "wait_signal_add", %{"a" => 5, "b" => 7, "signal" => "beta"}, "req-1")

      task_id = create["result"]["task"]["taskId"]

      assert_receive {:tool_running, worker, :beta}, 500
      send(worker, {:proceed, :beta})

      SyncHelpers.await_state(session, fn state ->
        not Map.has_key?(state.tasks, task_id)
      end)

      get = call_session(session, build_request("tasks/get", %{"taskId" => task_id}, "get-1"))
      assert get["result"]["taskId"] == task_id
      assert get["result"]["status"] == "completed"
    end

    test "returns -32602 for unknown taskId", %{session: session} do
      response = call_session(session, build_request("tasks/get", %{"taskId" => "does-not-exist"}, "get-1"))
      assert response["error"]["code"] == -32_602
    end
  end

  describe "tasks/result" do
    test "returns the underlying CallToolResult once terminal", %{session: session} do
      create =
        create_task_call(session, "wait_signal_add", %{"a" => 10, "b" => 20, "signal" => "gamma"}, "req-1")

      task_id = create["result"]["task"]["taskId"]

      assert_receive {:tool_running, worker, :gamma}, 500
      send(worker, {:proceed, :gamma})

      SyncHelpers.await_state(session, fn state -> not Map.has_key?(state.tasks, task_id) end)

      result = call_session(session, build_request("tasks/result", %{"taskId" => task_id}, "result-1"))

      assert [%{"type" => "text", "text" => "30"}] = result["result"]["content"]
      assert result["result"]["_meta"]["io.modelcontextprotocol/related-task"]["taskId"] == task_id
    end

    test "blocks until completion when called pre-terminal", %{session: session} do
      create =
        create_task_call(session, "wait_signal_add", %{"a" => 1, "b" => 2, "signal" => "delta"}, "req-1")

      task_id = create["result"]["task"]["taskId"]

      assert_receive {:tool_running, worker, :delta}, 500

      caller = self()

      Task.start(fn ->
        result =
          GenServer.call(
            session,
            {:mcp_request, build_request("tasks/result", %{"taskId" => task_id}, "result-1"), with_test_pid()}
          )

        send(caller, {:result_reply, result})
      end)

      # Wait until session has registered the waiter.
      SyncHelpers.await_state(session, fn state ->
        case Map.get(state.tasks, task_id) do
          %{waiters: [_ | _]} -> true
          _ -> false
        end
      end)

      refute_received {:result_reply, _}

      send(worker, {:proceed, :delta})

      assert_receive {:result_reply, {:ok, raw}}, 1_000
      decoded = decode_one(raw)
      assert [%{"text" => "3"}] = decoded["result"]["content"]
    end

    test "tool with isError: true reaches :failed status; tasks/result returns the CallToolResult verbatim", %{
      session: session
    } do
      create =
        create_task_call(session, "always_fails", %{"reason" => "kaboom"}, "req-1")

      task_id = create["result"]["task"]["taskId"]

      SyncHelpers.await_state(session, fn state -> not Map.has_key?(state.tasks, task_id) end)

      get = call_session(session, build_request("tasks/get", %{"taskId" => task_id}, "get-1"))
      assert get["result"]["status"] == "failed"

      # Per spec: tasks/result returns "exactly what the underlying request would
      # have returned." For tool calls, that's a CallToolResult — even when
      # isError: true.
      result = call_session(session, build_request("tasks/result", %{"taskId" => task_id}, "result-1"))
      assert result["result"]["isError"] == true
      assert [%{"text" => "kaboom"}] = result["result"]["content"]
    end
  end

  describe "tasks/cancel" do
    test "cancels a working task", %{session: session} do
      create =
        create_task_call(session, "wait_signal_add", %{"a" => 1, "b" => 2, "signal" => "epsilon"}, "req-1")

      task_id = create["result"]["task"]["taskId"]
      assert_receive {:tool_running, _worker, :epsilon}, 500

      response = call_session(session, build_request("tasks/cancel", %{"taskId" => task_id}, "cancel-1"))
      assert response["result"]["status"] == "cancelled"

      get = call_session(session, build_request("tasks/get", %{"taskId" => task_id}, "get-1"))
      assert get["result"]["status"] == "cancelled"
    end

    test "rejects cancellation of terminal task with -32602", %{session: session} do
      create =
        create_task_call(session, "wait_signal_add", %{"a" => 1, "b" => 2, "signal" => "zeta"}, "req-1")

      task_id = create["result"]["task"]["taskId"]
      assert_receive {:tool_running, worker, :zeta}, 500
      send(worker, {:proceed, :zeta})

      SyncHelpers.await_state(session, fn state -> not Map.has_key?(state.tasks, task_id) end)

      response = call_session(session, build_request("tasks/cancel", %{"taskId" => task_id}, "cancel-1"))
      assert response["error"]["code"] == -32_602
      assert response["error"]["data"]["message"] =~ "completed"
    end

    test "releases blocked tasks/result waiters with cancellation error", %{session: session} do
      create =
        create_task_call(session, "wait_signal_add", %{"a" => 1, "b" => 2, "signal" => "eta"}, "req-1")

      task_id = create["result"]["task"]["taskId"]
      assert_receive {:tool_running, _worker, :eta}, 500

      caller = self()

      Task.start(fn ->
        result =
          GenServer.call(
            session,
            {:mcp_request, build_request("tasks/result", %{"taskId" => task_id}, "result-1"), with_test_pid()}
          )

        send(caller, {:result_reply, result})
      end)

      SyncHelpers.await_state(session, fn state ->
        case Map.get(state.tasks, task_id) do
          %{waiters: [_ | _]} -> true
          _ -> false
        end
      end)

      cancel_response = call_session(session, build_request("tasks/cancel", %{"taskId" => task_id}, "cancel-1"))
      assert cancel_response["result"]["status"] == "cancelled"

      assert_receive {:result_reply, {:ok, raw}}, 500
      decoded = decode_one(raw)
      assert is_integer(decoded["error"]["code"])
    end
  end

  describe "tasks/list" do
    test "returns -32601 in Phase 1 (no auth context)", %{session: session} do
      response = call_session(session, build_request("tasks/list", %{}, "list-1"))
      assert response["error"]["code"] == -32_601
    end
  end

  describe "tasks/* against a session with no task_store configured" do
    test "tasks/get returns -32601 instead of crashing" do
      session = start_no_task_store_session()
      response = call_session(session, build_request("tasks/get", %{"taskId" => "x"}, "get-1"))
      assert response["error"]["code"] == -32_601
      assert Process.alive?(session)
    end

    test "tasks/result returns -32601 instead of crashing" do
      session = start_no_task_store_session()
      response = call_session(session, build_request("tasks/result", %{"taskId" => "x"}, "result-1"))
      assert response["error"]["code"] == -32_601
      assert Process.alive?(session)
    end
  end

  describe "tools/list rendering" do
    test "renders execution.taskSupport for opt-in tools", %{session: session} do
      response = call_session(session, build_request("tools/list", %{}, "list-1"))

      tools = response["result"]["tools"]
      by_name = Map.new(tools, &{&1["name"], &1})

      assert by_name["wait_signal_add"]["execution"] == %{"taskSupport" => "optional"}
      assert by_name["must_be_task"]["execution"] == %{"taskSupport" => "required"}
      assert by_name["always_fails"]["execution"] == %{"taskSupport" => "optional"}
      refute Map.has_key?(by_name["no_tasks"], "execution")
    end
  end

  describe "TTL expiry" do
    test "expired task is purged and tasks/get returns -32602", %{session: session, task_store: store} do
      create =
        create_task_call(session, "wait_signal_add", %{"a" => 1, "b" => 2, "signal" => "theta"}, "req-1")

      task_id = create["result"]["task"]["taskId"]
      assert_receive {:tool_running, worker, :theta}, 500

      # Trigger expiry directly instead of waiting for a timer to fire.
      send(session, {:task_expired, task_id})

      SyncHelpers.await_state(session, fn state -> not Map.has_key?(state.tasks, task_id) end)

      assert {:error, :not_found} = store.adapter.get(store.name, "tasks-session", task_id)

      response = call_session(session, build_request("tasks/get", %{"taskId" => task_id}, "get-1"))
      assert response["error"]["code"] == -32_602

      # Release the worker so it doesn't linger.
      send(worker, {:proceed, :theta})
    end
  end

  describe "notifications/tasks/status" do
    test "Server.send_task_status emits notification with full task projection", %{
      session: session,
      transport: transport
    } do
      :ok = StubTransport.set_test_pid(transport, self())

      create =
        create_task_call(session, "wait_signal_add", %{"a" => 1, "b" => 2, "signal" => "iota"}, "req-1")

      task_id = create["result"]["task"]["taskId"]
      assert_receive {:tool_running, _worker, :iota}, 500

      send(session, {:send_task_status, task_id})

      assert_receive {:send_message, raw}, 500
      decoded = decode_one(raw)
      assert decoded["method"] == "notifications/tasks/status"
      assert decoded["params"]["taskId"] == task_id
      assert decoded["params"]["status"] == "working"
      # Spec: notifications/tasks/status SHOULD NOT include related-task in _meta.
      refute get_in(decoded, ["params", "_meta", "io.modelcontextprotocol/related-task"])
    end
  end

  # ─── helpers ───────────────────────────────────────────────────────────

  defp start_tasks_session(_ctx) do
    session_id = "tasks-session"
    transport_name = Registry.transport_name(TasksStubServer, StubTransport)
    transport = start_supervised!({StubTransport, name: transport_name})

    task_sup = Registry.task_supervisor_name(TasksStubServer)
    start_supervised!({Task.Supervisor, name: task_sup})

    task_store_name = Registry.task_store_name(TasksStubServer)
    start_supervised!({TaskStoreLocal, name: task_store_name})

    session_name = Registry.session_name(TasksStubServer, session_id)

    session =
      start_supervised!(
        {Session,
         session_id: session_id,
         server_module: TasksStubServer,
         name: session_name,
         transport: [layer: StubTransport, name: transport_name],
         task_supervisor: task_sup,
         task_store: [adapter: TaskStoreLocal, name: task_store_name]}
      )

    request = init_request("2025-11-25", %{"name" => "TestClient", "version" => "1.0.0"})
    {:ok, _} = GenServer.call(session, {:mcp_request, request, with_test_pid()})

    init_notification = build_notification("notifications/initialized", %{})
    :ok = GenServer.cast(session, {:mcp_notification, init_notification, with_test_pid()})

    SyncHelpers.await_state(session, & &1.initialized)
    StubTransport.clear(transport)

    %{
      session: session,
      transport: transport,
      session_id: session_id,
      task_store: %{adapter: TaskStoreLocal, name: task_store_name}
    }
  end

  defp start_no_task_store_session do
    session_id = "no-store-#{System.unique_integer([:positive])}"
    transport_name = Registry.transport_name(TasksStubServer, StubTransport)
    task_sup = Registry.task_supervisor_name(TasksStubServer)
    session_name = Registry.session_name(TasksStubServer, session_id)

    session =
      start_supervised!(
        {Session,
         session_id: session_id,
         server_module: TasksStubServer,
         name: session_name,
         transport: [layer: StubTransport, name: transport_name],
         task_supervisor: task_sup},
        id: {:no_store_session, session_id}
      )

    request = init_request("2025-11-25", %{"name" => "TestClient", "version" => "1.0.0"})
    {:ok, _} = GenServer.call(session, {:mcp_request, request, with_test_pid()})

    init_notification = build_notification("notifications/initialized", %{})
    :ok = GenServer.cast(session, {:mcp_notification, init_notification, with_test_pid()})

    SyncHelpers.await_state(session, & &1.initialized)
    session
  end

  defp with_test_pid, do: %{assigns: %{test_pid: self()}}

  defp build_request_with_task(name, args, id, opts \\ []) do
    task_block = if ttl = opts[:ttl], do: %{"ttl" => ttl}, else: %{}

    build_request(
      "tools/call",
      %{"name" => name, "arguments" => args, "task" => task_block},
      id
    )
  end

  defp call_session(session, request) do
    {:ok, raw} = GenServer.call(session, {:mcp_request, request, with_test_pid()})
    decode_one(raw)
  end

  defp create_task_call(session, name, args, id, opts \\ []) do
    call_session(session, build_request_with_task(name, args, id, opts))
  end

  defp decode_one(raw) do
    {:ok, [decoded]} = Message.decode(raw)
    decoded
  end
end
