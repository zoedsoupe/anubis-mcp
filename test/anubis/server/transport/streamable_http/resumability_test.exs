defmodule Anubis.Server.Transport.StreamableHTTP.ResumabilityTest.FailingStore do
  @moduledoc false
  @behaviour Anubis.Server.Transport.StreamableHTTP.EventStore

  @impl true
  def child_spec(_opts), do: :ignore
  @impl true
  def append(_name, _session_id, _data), do: {:error, :boom}
  @impl true
  def replay(_name, _session_id, _after_id), do: {:error, :boom}
  @impl true
  def latest_id(_name, _session_id), do: {:ok, 0}
  @impl true
  def delete(_name, _session_id), do: :ok
end

defmodule Anubis.Server.Transport.StreamableHTTP.ResumabilityTest do
  use Anubis.MCP.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Anubis.Server.Registry
  alias Anubis.Server.Supervisor, as: ServerSupervisor
  alias Anubis.Server.Transport.StreamableHTTP
  alias Anubis.Server.Transport.StreamableHTTP.EventStore.InMemory
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug
  alias Anubis.Server.Transport.StreamableHTTP.ResumabilityTest.FailingStore
  alias Anubis.SSE.Streaming

  @moduletag capture_log: true

  defp start_store(opts \\ []) do
    name = :"event_store_#{System.unique_integer([:positive])}"
    start_supervised!({InMemory, Keyword.put(opts, :name, name)})
    name
  end

  # Runs a resumable SSE stream to completion and returns the raw chunk stream.
  # Priming and replay happen synchronously at start; `feed` then sends live
  # messages, and `:close_sse` terminates the loop. Mailbox ordering makes the
  # chunk sequence deterministic without sleeps.
  defp run_stream(store_ref, session_id, opts, feed) do
    conn = conn(:get, "/")

    task =
      Task.async(fn ->
        conn
        |> Streaming.prepare_connection()
        |> Streaming.start(:test_transport, session_id,
          event_store: store_ref,
          resume_from: Keyword.get(opts, :resume_from),
          retry: Keyword.get(opts, :retry),
          on_close: fn -> :ok end
        )
      end)

    feed.(task.pid)
    send(task.pid, :close_sse)

    task
    |> Task.await(2_000)
    |> chunks()
  end

  defp chunks(%Plug.Conn{} = conn) do
    case conn.adapter do
      {Plug.Adapters.Test.Conn, %{chunks: chunks}} when is_binary(chunks) -> chunks
      _ -> ""
    end
  end

  defp occurrences(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end

  # Spawns a process that registers itself as the SSE handler and blocks, so the
  # test can kill it to simulate a client disconnect that fires the DOWN monitor.
  defp register_killable_handler(transport, session_id) do
    test = self()

    pid =
      spawn(fn ->
        :ok = StreamableHTTP.register_sse_handler(transport, session_id)
        send(test, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^pid}
    pid
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end

  describe "priming event" do
    test "fresh connect primes with the session high-water id and empty data" do
      store = start_store()
      store_name = store
      InMemory.append(store_name, "s1", "old-a")
      InMemory.append(store_name, "s1", "old-b")

      out = run_stream({InMemory, store_name}, "s1", [resume_from: nil], fn _pid -> :ok end)

      # High-water is 2, so the priming cursor is 2 and no old event is replayed.
      assert out =~ "id: 2\n\n"
      refute out =~ "data: old-a"
    end

    test "brand-new session primes with id 0" do
      store = start_store()
      out = run_stream({InMemory, store}, "fresh", [resume_from: nil], fn _pid -> :ok end)
      assert out =~ "id: 0\n\n"
    end

    test "emits the retry field on the priming event when configured" do
      store = start_store()
      out = run_stream({InMemory, store}, "s1", [resume_from: nil, retry: 30_000], fn _pid -> :ok end)
      assert out =~ "id: 0\nretry: 30000\n\n"
    end
  end

  describe "replay on reconnect" do
    test "replays events after Last-Event-ID, in order, before live events" do
      store = start_store()
      for data <- ~w(a b c), do: InMemory.append(store, "s1", data)

      out =
        run_stream({InMemory, store}, "s1", [resume_from: 1], fn pid ->
          send(pid, {:sse_message, "live", 4})
        end)

      assert out =~ "id: 1\n\n"
      assert out =~ "id: 2\nevent: message\ndata: b\n\n"
      assert out =~ "id: 3\nevent: message\ndata: c\n\n"
      assert out =~ "id: 4\nevent: message\ndata: live\n\n"

      assert index(out, "data: b") < index(out, "data: c")
      assert index(out, "data: c") < index(out, "data: live")
      refute out =~ "data: a"
    end

    test "drops a live event already delivered during replay (exactly-once)" do
      store = start_store()
      InMemory.append(store, "s1", "a")
      InMemory.append(store, "s1", "b")

      out =
        run_stream({InMemory, store}, "s1", [resume_from: 0], fn pid ->
          # Reproduces the register-then-replay race: id 2 was already replayed
          # and now arrives again as a live push.
          send(pid, {:sse_message, "b", 2})
          send(pid, {:sse_message, "c", 3})
        end)

      assert occurrences(out, "data: b") == 1
      assert out =~ "id: 3\nevent: message\ndata: c\n\n"
    end

    test "a stale Last-Event-ID above the store high-water still delivers live events" do
      # Reproduces the post-restart / LRU-reset case: the store is empty but the
      # client presents an old cursor of 42. Replay yields nothing, so the dedupe
      # floor must stay at 0 and live ids (starting at 1) must NOT be dropped.
      store = start_store()

      out =
        run_stream({InMemory, store}, "s1", [resume_from: 42], fn pid ->
          send(pid, {:sse_message, "live-1", 1})
          send(pid, {:sse_message, "live-2", 2})
        end)

      assert out =~ "id: 1\nevent: message\ndata: live-1\n\n"
      assert out =~ "id: 2\nevent: message\ndata: live-2\n\n"
    end

    test "a fresh connect against a session with history does not drop raced live events" do
      # High-water is 2, so priming echoes 2, but nothing is replayed on a fresh
      # connect; the dedupe floor must be 0 so an event that raced registration
      # (id 3) is delivered rather than dropped.
      store = start_store()
      InMemory.append(store, "s1", "old-a")
      InMemory.append(store, "s1", "old-b")

      out =
        run_stream({InMemory, store}, "s1", [resume_from: nil], fn pid ->
          send(pid, {:sse_message, "raced", 3})
        end)

      assert out =~ "id: 3\nevent: message\ndata: raced\n\n"
    end
  end

  defp index(haystack, needle) do
    case :binary.match(haystack, needle) do
      {start, _len} -> start
      :nomatch -> -1
    end
  end

  describe "transport recording" do
    setup do
      store_name = start_store()
      transport_name = :"transport_#{System.unique_integer([:positive])}"
      task_sup = :"task_sup_#{System.unique_integer([:positive])}"
      start_supervised!({Task.Supervisor, name: task_sup})

      {:ok, transport} =
        start_supervised(
          {StreamableHTTP,
           server: StubServer,
           name: transport_name,
           task_supervisor: task_sup,
           event_store: {InMemory, store_name},
           keepalive: false}
        )

      %{transport: transport, store: store_name}
    end

    test "records and delivers a routed event with its assigned id", %{transport: transport, store: store} do
      session = "route-session"
      assert :ok = StreamableHTTP.register_sse_handler(transport, session)

      assert :ok = StreamableHTTP.route_to_session(transport, session, "hello")

      assert_receive {:sse_message, "hello", 1}
      assert {:ok, [{1, "hello"}]} = InMemory.replay(store, session, 0)
    end

    test "records broadcast events into every open stream and delivers to attached handlers",
         %{transport: transport, store: store} do
      session = "broadcast-session"
      assert :ok = StreamableHTTP.register_sse_handler(transport, session)

      assert :ok = StreamableHTTP.send_message(transport, "bcast", timeout: 5_000)

      assert_receive {:sse_message, "bcast", 1}
      assert {:ok, [{1, "bcast"}]} = InMemory.replay(store, session, 0)
    end

    test "keeps recording during a reconnect gap when no handler is attached",
         %{transport: transport, store: store} do
      session = "gap-session"
      # Open the stream, then drop the handler while leaving the stream open.
      assert :ok = StreamableHTTP.register_sse_handler(transport, session)
      StreamableHTTP.unregister_sse_handler(transport, session)

      assert :ok = StreamableHTTP.send_message(transport, "gap-event", timeout: 5_000)

      refute_receive {:sse_message, _, _}, 50
      assert {:ok, [{1, "gap-event"}]} = InMemory.replay(store, session, 0)
    end

    test "close_session_stream drops recorded events", %{transport: transport, store: store} do
      session = "close-session"
      assert :ok = StreamableHTTP.register_sse_handler(transport, session)
      assert :ok = StreamableHTTP.route_to_session(transport, session, "e1")
      assert {:ok, [{1, "e1"}]} = InMemory.replay(store, session, 0)

      StreamableHTTP.close_session_stream(transport, session)
      _ = :sys.get_state(transport)

      assert {:ok, []} = InMemory.replay(store, session, 0)
    end

    test "resumability_config exposes the store reference and retry", %{transport: transport, store: store} do
      assert {{InMemory, ^store}, nil} = StreamableHTTP.resumability_config(transport)
    end

    test "an append failure is not delivered as a mis-numbered legacy event" do
      # A store whose append errors must NOT fall back to a 2-tuple (legacy id)
      # on the resumable stream, which would collide with the store id space.
      store_ref = {FailingStore, :failing}
      task_sup = :"task_sup_#{System.unique_integer([:positive])}"
      start_supervised!({Task.Supervisor, name: task_sup})

      {:ok, transport} =
        start_supervised(
          {StreamableHTTP,
           server: StubServer,
           name: :"transport_#{System.unique_integer([:positive])}",
           task_supervisor: task_sup,
           event_store: store_ref,
           keepalive: false},
          id: :failing_transport
        )

      session = "append-fails"
      assert :ok = StreamableHTTP.register_sse_handler(transport, session)
      # The append failure is surfaced to the caller rather than reported as a
      # phantom success, and nothing is delivered with a fabricated legacy id.
      assert {:error, :boom} = StreamableHTTP.send_message(transport, "dropped", timeout: 5_000)

      refute_receive {:sse_message, _}, 50
      refute_receive {:sse_message, _, _}, 50
    end
  end

  describe "stream lifecycle (grace timer)" do
    setup do
      store_name = start_store()
      task_sup = :"task_sup_#{System.unique_integer([:positive])}"
      start_supervised!({Task.Supervisor, name: task_sup})

      {:ok, transport} =
        start_supervised(
          {StreamableHTTP,
           server: StubServer,
           name: :"transport_#{System.unique_integer([:positive])}",
           task_supervisor: task_sup,
           event_store: {InMemory, store_name},
           keepalive: false,
           stream_grace: 60}
        )

      %{transport: transport, store: store_name}
    end

    test "drops the stream after the grace window with no reconnect", %{transport: transport, store: store} do
      session = "grace-close"
      handler = register_killable_handler(transport, session)
      assert :ok = StreamableHTTP.route_to_session(transport, session, "e1")
      assert {:ok, [{1, "e1"}]} = InMemory.replay(store, session, 0)

      Process.exit(handler, :kill)
      assert wait_until(fn -> StreamableHTTP.get_sse_handler(transport, session) == nil end)

      # After the 60ms grace timer fires, the stream is closed and events dropped.
      assert wait_until(fn -> InMemory.replay(store, session, 0) == {:ok, []} end)
    end

    test "a reconnect within the grace window keeps the stream", %{transport: transport, store: store} do
      session = "grace-keep"
      handler = register_killable_handler(transport, session)
      assert :ok = StreamableHTTP.route_to_session(transport, session, "e1")

      Process.exit(handler, :kill)
      assert wait_until(fn -> StreamableHTTP.get_sse_handler(transport, session) == nil end)

      # Reconnect before the grace timer fires; it must be cancelled.
      reconnected = register_killable_handler(transport, session)
      Process.sleep(120)
      _ = :sys.get_state(transport)

      assert {:ok, [{1, "e1"}]} = InMemory.replay(store, session, 0)

      send(reconnected, :stop)
    end
  end

  describe "Plug Last-Event-ID wiring" do
    setup do
      store_name = start_store()
      transport_name = Registry.transport_name(StubServer, :streamable_http)
      task_sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: task_sup})

      {:ok, transport} =
        start_supervised(
          {StreamableHTTP,
           server: StubServer,
           name: transport_name,
           task_supervisor: task_sup,
           event_store: {InMemory, store_name},
           sse_retry: 25_000,
           keepalive: false}
        )

      session_config = %{
        server_module: StubServer,
        registry_mod: Registry.None,
        transport: [layer: :streamable_http, name: transport_name],
        session_idle_timeout: nil,
        timeout: 30_000,
        task_supervisor: task_sup
      }

      :persistent_term.put({ServerSupervisor, StubServer, :session_config}, session_config)
      on_exit(fn -> :persistent_term.erase({ServerSupervisor, StubServer, :session_config}) end)

      opts = StreamableHTTPPlug.init(server: StubServer)
      %{opts: opts, transport: transport, store: store_name}
    end

    test "a GET with Last-Event-ID primes on the client cursor and replays after it",
         %{opts: opts, transport: transport, store: store} do
      session = "plug-resume"
      for data <- ~w(a b c), do: InMemory.append(store, session, data)

      conn =
        :get
        |> conn("/")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("mcp-session-id", session)
        |> put_req_header("last-event-id", "1")

      task = Task.async(fn -> StreamableHTTPPlug.call(conn, opts) end)

      # The GET handler is now blocked in the streaming loop; close it once the
      # priming + replay chunks have been written.
      handler = wait_for_handler(transport, session)
      send(handler, :close_sse)

      out = chunks(Task.await(task, 2_000))

      # retry surfaced from transport config; priming echoes cursor 1; b and c replayed.
      assert out =~ "id: 1\nretry: 25000\n\n"
      assert out =~ "id: 2\nevent: message\ndata: b\n\n"
      assert out =~ "id: 3\nevent: message\ndata: c\n\n"
      refute out =~ "data: a"
    end

    test "a GET with a negative or non-numeric Last-Event-ID primes as a fresh connect",
         %{opts: opts, transport: transport} do
      for bad <- ["-1", "abc"] do
        session = "plug-bad-cursor-#{bad}"

        conn =
          :get
          |> conn("/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("mcp-session-id", session)
          |> put_req_header("last-event-id", bad)

        task = Task.async(fn -> StreamableHTTPPlug.call(conn, opts) end)

        handler = wait_for_handler(transport, session)
        send(handler, :close_sse)

        out = chunks(Task.await(task, 2_000))

        # The malformed cursor is rejected, so the stream primes fresh (high-water
        # 0 for this never-seen session) instead of crashing or resuming on a bogus
        # negative cursor.
        assert out =~ "id: 0\nretry: 25000\n\n"
        refute out =~ "id: -1"
      end
    end
  end

  defp wait_for_handler(transport, session_id, attempts \\ 200)

  defp wait_for_handler(_transport, _session_id, 0), do: flunk("SSE handler never registered")

  defp wait_for_handler(transport, session_id, attempts) do
    case StreamableHTTP.get_sse_handler(transport, session_id) do
      pid when is_pid(pid) ->
        pid

      nil ->
        Process.sleep(5)
        wait_for_handler(transport, session_id, attempts - 1)
    end
  end
end
