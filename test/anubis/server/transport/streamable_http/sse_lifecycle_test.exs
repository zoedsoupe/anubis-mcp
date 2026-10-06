defmodule Anubis.Server.Transport.StreamableHTTP.SSELifecycleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Anubis.Server.Registry
  alias Anubis.Server.Supervisor, as: ServerSupervisor
  alias Anubis.Server.Transport.StreamableHTTP
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug
  alias Anubis.Test.SSEAdapter

  setup context do
    task_sup = Registry.task_supervisor_name(StubServer)
    start_supervised!({Task.Supervisor, name: task_sup})

    transport =
      start_supervised!(
        {StreamableHTTP,
         server: StubServer,
         name: Registry.transport_name(StubServer, :streamable_http),
         task_supervisor: task_sup,
         keepalive: Map.get(context, :keepalive, true),
         keepalive_interval: 30}
      )

    key = {ServerSupervisor, StubServer, :session_config}
    :persistent_term.put(key, %{registry_mod: Registry.None})
    on_exit(fn -> :persistent_term.erase(key) end)

    %{transport: transport, task_sup: task_sup, opts: StreamableHTTPPlug.init(server: StubServer)}
  end

  @tag keepalive: false
  test "DELETE releases the GET stream even with keepalives disabled", context do
    {stream, _disconnected} = open_stream(context, "delete-stream")

    assert delete_request(context, "delete-stream").status == 200
    assert {:ok, %{halted: true}} = Task.yield(stream, 1_000)
    assert StreamableHTTP.get_sse_handler(context.transport, "delete-stream") == nil
  end

  test "a superseded stream detects its disconnected client without transport keepalives", context do
    {old, disconnected} = open_stream(context, "replaced-stream")
    {current, _} = open_stream(context, "replaced-stream")
    assert StreamableHTTP.get_sse_handler(context.transport, "replaced-stream") == current.pid

    log =
      capture_log(fn ->
        :atomics.put(disconnected, 1, 1)
        assert {:ok, _conn} = Task.yield(old, 1_000)
      end)

    assert log =~ "sse_keepalive_failed"
    assert log =~ "reason: :closed"
    assert StreamableHTTP.get_sse_handler(context.transport, "replaced-stream") == current.pid
    assert :ok = StreamableHTTP.route_to_session(context.transport, "replaced-stream", "still connected")
    current_pid = current.pid
    assert_receive {:sse_chunk, ^current_pid, <<"id:", _::binary>> = chunk}
    assert chunk =~ "data: still connected"
    send(current.pid, :close_sse)
    assert {:ok, _} = Task.yield(current, 1_000)
  end

  test "a superseded live stream stays open and keeps probing its connection", context do
    {old, _} = open_stream(context, "live-stream")
    {current, _} = open_stream(context, "live-stream")
    old_pid = old.pid

    assert_receive {:sse_chunk, ^old_pid, ": keepalive\n\n"}, 300
    assert Process.alive?(old.pid)
    assert StreamableHTTP.get_sse_handler(context.transport, "live-stream") == current.pid

    for stream <- [old, current] do
      send(stream.pid, :close_sse)
      assert {:ok, _} = Task.yield(stream, 1_000)
    end
  end

  @tag keepalive: false
  test "disabled keepalives stay disabled after replacement", context do
    {old, _} = open_stream(context, "quiet-stream")
    {current, _} = open_stream(context, "quiet-stream")
    refute_receive {:sse_chunk, _, _}, 100

    for stream <- [old, current] do
      send(stream.pid, :close_sse)
      assert {:ok, _} = Task.yield(stream, 1_000)
    end
  end

  defp open_stream(context, session_id) do
    conn =
      :get
      |> conn("/mcp")
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("mcp-session-id", session_id)

    {_, payload} = conn.adapter
    disconnected = :atomics.new(1, [])
    conn = %{conn | adapter: {SSEAdapter, Map.put(payload, :disconnected, disconnected)}}
    task = Task.Supervisor.async_nolink(context.task_sup, fn -> StreamableHTTPPlug.call(conn, context.opts) end)
    pid = task.pid
    assert_receive {:sse_opened, ^pid}
    {task, disconnected}
  end

  defp delete_request(context, session_id) do
    :delete
    |> conn("/mcp")
    |> put_req_header("mcp-session-id", session_id)
    |> StreamableHTTPPlug.call(context.opts)
  end
end
