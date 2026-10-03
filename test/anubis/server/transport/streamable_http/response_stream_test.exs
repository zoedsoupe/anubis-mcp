defmodule Anubis.Server.Transport.StreamableHTTP.ResponseStreamTest do
  use Anubis.MCP.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Anubis.Server.Component
  alias Anubis.Server.Registry
  alias Anubis.Server.Supervisor, as: ServerSupervisor
  alias Anubis.Server.Transport.StreamableHTTP
  alias Anubis.Server.Transport.StreamableHTTP.EventStore.InMemory
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug
  alias Plug.Adapters.Test.Conn

  @moduletag capture_log: false

  @version "2026-07-28"

  defmodule ProgressTool do
    @moduledoc false
    use Component, type: :tool

    alias Anubis.Server.Frame
    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      if token = Frame.progress_token(frame) do
        for step <- [0, 50, 100], do: Anubis.Server.send_progress(token, step, total: 100)
      end

      Anubis.Server.send_tools_list_changed()
      {:reply, Response.text(Response.tool(), "done"), frame}
    end
  end

  defmodule LogTool do
    @moduledoc false
    use Component, type: :tool

    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      Anubis.Server.send_log_message(:debug, "detail")
      Anubis.Server.send_log_message(:info, "working")
      {:reply, Response.text(Response.tool(), "logged"), frame}
    end
  end

  defmodule SlowTool do
    @moduledoc false
    use Component, type: :tool

    alias Anubis.Server.Frame
    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      send(ResponseStreamTest, {:tool_running, self()})

      receive do
        :finish ->
          if token = Frame.progress_token(frame), do: Anubis.Server.send_progress(token, 100)
          {:reply, Response.text(Response.tool(), "finished"), frame}
      end
    end
  end

  defmodule ClosedSocket do
    @moduledoc false
    # The test adapter can close before any chunk or only on the final response.
    alias Conn, as: TestConn

    defdelegate send_resp(payload, status, headers, body), to: TestConn
    defdelegate send_file(payload, status, headers, path, offset, length), to: TestConn
    defdelegate send_chunked(payload, status, headers), to: TestConn
    defdelegate read_req_body(payload, opts), to: TestConn
    defdelegate inform(payload, status, headers), to: TestConn
    defdelegate upgrade(payload, protocol, opts), to: TestConn
    defdelegate push(payload, path, headers), to: TestConn
    defdelegate get_peer_data(payload), to: TestConn
    defdelegate get_http_protocol(payload), to: TestConn
    defdelegate get_sock_data(payload), to: TestConn
    defdelegate get_ssl_data(payload), to: TestConn

    def chunk(%{close_on_response: true} = payload, body) do
      if body |> IO.iodata_to_binary() |> String.contains?("\"id\":"),
        do: {:error, :closed},
        else: TestConn.chunk(payload, body)
    end

    def chunk(_payload, _body), do: {:error, :closed}
  end

  defmodule StreamingServer do
    @moduledoc false
    use Anubis.Server,
      name: "streaming-server",
      version: "1.0.0",
      capabilities: [{:tools, list_changed?: true}],
      protocol_versions: ["2026-07-28"]

    alias Anubis.Server.Frame
    alias Anubis.Server.Handlers

    component(ProgressTool, name: "progress")
    component(SlowTool, name: "slow")
    component(LogTool, name: "log")

    @impl true
    def handle_request(%{"method" => "tools/call", "params" => %{"name" => name}}, frame)
        when name in ["no_reply", "slow_no_reply"] do
      if token = Frame.progress_token(frame), do: Anubis.Server.send_progress(token, 100)

      if name == "slow_no_reply" do
        send(ResponseStreamTest, {:tool_running, self()})

        receive do
          :finish -> :ok
        end
      end

      {:noreply, frame}
    end

    def handle_request(request, frame), do: Handlers.handle(request, __MODULE__, frame)
  end

  setup context do
    server = StreamingServer
    task_sup = Registry.task_supervisor_name(server)
    start_supervised!({Task.Supervisor, name: task_sup})

    registry_name = Registry.registry_name(server)
    start_supervised!({Registry.Local, name: registry_name})
    naming_registry = Registry.naming_registry_name(registry_name)
    start_supervised!({Elixir.Registry, keys: :unique, name: naming_registry})
    session_sup = Registry.session_supervisor_name(server)
    start_supervised!({DynamicSupervisor, name: session_sup, strategy: :one_for_one})

    http_transport = Registry.transport_name(server, :streamable_http)

    transport_opts = [server: server, name: http_transport, task_supervisor: task_sup, keepalive: false]

    transport_opts =
      if context[:event_store] do
        store = start_supervised!({InMemory, name: :response_stream_store, max_sessions: 2})
        Keyword.put(transport_opts, :event_store, {InMemory, store})
      else
        transport_opts
      end

    start_supervised!({StreamableHTTP, transport_opts})

    :persistent_term.put({ServerSupervisor, server, :session_config}, %{
      server_module: server,
      registry_mod: Registry.Local,
      transport: [layer: StreamableHTTP, name: http_transport],
      session_idle_timeout: nil,
      timeout: 30_000,
      task_supervisor: task_sup
    })

    on_exit(fn -> :persistent_term.erase({ServerSupervisor, server, :session_config}) end)

    %{opts: StreamableHTTPPlug.init(server: server)}
  end

  @tag event_store: true
  test "request streams leave legacy replay history intact", %{opts: opts} do
    store = :response_stream_store
    transport = Registry.transport_name(StreamingServer, :streamable_http)
    :ok = StreamableHTTP.register_sse_handler(transport, "legacy")
    :ok = StreamableHTTP.send_message(transport, "legacy-event", session_id: "legacy")
    assert_receive {:sse_message, "legacy-event", id}
    :ok = StreamableHTTP.unregister_sse_handler(transport, "legacy")

    for _ <- 1..3 do
      conn = call(opts, %{"progressToken" => "tok"}, "application/json, text/event-stream")
      assert [_, _, _, %{"result" => _}] = events(conn)
    end

    assert {:ok, [{^id, "legacy-event"}]} = InMemory.replay(store, "legacy", 0)
    state = :sys.get_state(transport)
    assert state.streams == MapSet.new(["legacy"])
    assert Map.keys(state.stream_timers) == ["legacy"]
    assert state.sse_handlers == %{}
    :ok = StreamableHTTP.send_message(transport, "broadcast", [])
    assert {:ok, [{^id, "legacy-event"}, {_, "broadcast"}]} = InMemory.replay(store, "legacy", 0)
  end

  test "progress streams ahead of the result when the client accepts SSE", %{opts: opts} do
    conn = call(opts, %{"progressToken" => "tok"}, "application/json, text/event-stream")

    assert conn.status == 200
    assert [content_type | _] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"

    assert [p0, p50, p100, result] = events(conn)
    assert Enum.map([p0, p50, p100], & &1["params"]["progress"]) == [0, 50, 100]
    assert p0["params"]["progressToken"] == "tok"
    assert %{"id" => 1, "result" => %{"content" => [%{"text" => "done"}]}} = result
  end

  test "a request that asks for no progress is answered as JSON", %{opts: opts} do
    conn = call(opts, %{}, "application/json, text/event-stream")

    assert [content_type | _] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"
    assert %{"result" => %{"content" => [%{"text" => "done"}]}} = JSON.decode!(conn.resp_body)
  end

  test "a client that accepts only JSON gets JSON, progress or not", %{opts: opts} do
    conn = call_without_stream(opts, "application/json")

    assert %{"result" => %{"content" => [%{"text" => "done"}]}} = JSON.decode!(conn.resp_body)
  end

  test "a client that marks the stream unacceptable gets JSON, progress or not", %{opts: opts} do
    conn = call_without_stream(opts, "application/json, text/event-stream;q=0")

    assert [content_type | _] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"
    assert %{"result" => %{"content" => [%{"text" => "done"}]}} = JSON.decode!(conn.resp_body)
  end

  test "notifications that are not request-scoped stay off the response", %{opts: opts} do
    conn = call(opts, %{"progressToken" => "tok"}, "application/json, text/event-stream")

    refute Enum.any?(events(conn), &(&1["method"] == "notifications/tools/list_changed"))
  end

  test "a log message streams ahead of the result when the request set a log level", %{opts: opts} do
    conn = call(opts, %{"io.modelcontextprotocol/logLevel" => "info"}, "application/json, text/event-stream", "log")

    assert [log, result] = events(conn)
    assert %{"method" => "notifications/message", "params" => %{"level" => "info", "data" => "working"}} = log
    assert %{"id" => 1, "result" => %{"content" => [%{"text" => "logged"}]}} = result
  end

  test "a request that outlives a keepalive is answered over SSE", %{opts: opts} do
    Process.register(self(), ResponseStreamTest)
    request = Task.async(fn -> call(opts, %{}, "application/json, text/event-stream", "slow") end)

    assert_receive {:tool_running, tool}
    send(request.pid, :sse_keepalive)
    send(tool, :finish)
    conn = Task.await(request)

    assert [content_type | _] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert chunks(conn) =~ ": keepalive"
    assert [%{"id" => 1, "result" => %{"content" => [%{"text" => "finished"}]}}] = events(conn)
  end

  test "a no-reply completion before streaming returns HTTP 202", %{opts: opts} do
    conn = call(opts, %{}, "application/json, text/event-stream", "no_reply")

    assert conn.status == 202
    assert conn.resp_body == ""
  end

  test "a no-reply completion after progress closes without an error response", %{opts: opts} do
    conn = call(opts, %{"progressToken" => "tok"}, "application/json, text/event-stream", "no_reply")

    assert conn.status == 200
    assert [%{"method" => "notifications/progress", "params" => %{"progress" => 100}}] = events(conn)
  end

  test "a no-reply completion after a keepalive closes without an error response", %{opts: opts} do
    Process.register(self(), ResponseStreamTest)
    request = Task.async(fn -> call(opts, %{}, "application/json, text/event-stream", "slow_no_reply") end)

    assert_receive {:tool_running, handler}
    send(request.pid, :sse_keepalive)
    send(handler, :finish)
    conn = Task.await(request)

    assert conn.status == 200
    assert chunks(conn) == ": keepalive\n\n"
    assert events(conn) == []
  end

  for event_store? <- [false, true] do
    @tag event_store: event_store?
    test "broadcasts stay off request streams with event_store=#{event_store?}", %{opts: opts, event_store: stored?} do
      Process.register(self(), ResponseStreamTest)
      transport = Registry.transport_name(StreamingServer, :streamable_http)
      :ok = StreamableHTTP.register_sse_handler(transport, "listener")
      meta = %{"progressToken" => "own", "io.modelcontextprotocol/logLevel" => "info"}
      request = Task.async(fn -> call(opts, meta, "application/json, text/event-stream", "slow") end)
      assert_receive {:tool_running, tool}

      progress =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{"progressToken" => "unrelated", "progress" => 50}
        })

      log =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/message",
          "params" => %{"level" => "info", "data" => "unrelated"}
        })

      :ok = StreamableHTTP.send_message(transport, progress, [])
      :ok = StreamableHTTP.send_message_to_subscribers(transport, fn _metadata -> true end, log)

      if stored? do
        assert_receive {:sse_message, ^progress, _event_id}
      else
        assert_receive {:sse_message, ^progress}
      end

      assert_receive {:sse_message, ^log}

      send(tool, :finish)
      conn = Task.await(request)

      assert [
               %{"method" => "notifications/progress", "params" => %{"progressToken" => "own", "progress" => 100}},
               %{"id" => 1, "result" => %{"content" => [%{"text" => "finished"}]}}
             ] = events(conn)

      assert StreamableHTTP.handler_count(transport) == 1
    end
  end

  test "a client that disconnects cancels the running tool", %{opts: opts} do
    Process.register(self(), ResponseStreamTest)

    request =
      Task.async(fn ->
        opts
        |> request(%{}, "application/json, text/event-stream", "slow")
        |> Map.update!(:adapter, fn {_test_conn, state} -> {ClosedSocket, state} end)
        |> StreamableHTTPPlug.call(opts)
      end)

    assert_receive {:tool_running, tool}
    tool_ref = Process.monitor(tool)
    send(request.pid, :sse_keepalive)

    assert_receive {:DOWN, ^tool_ref, :process, ^tool, _reason}
    Task.await(request)
  end

  test "a disconnect during the final response logs its reason", %{opts: opts} do
    {conn, log} =
      with_log(fn ->
        logging = Application.get_env(:anubis_mcp, :logging, [])
        Application.put_env(:anubis_mcp, :logging, Keyword.put(logging, :transport_events, :warning))

        try do
          opts
          |> request(%{"progressToken" => "tok"}, "application/json, text/event-stream", "progress")
          |> Map.update!(:adapter, fn {_test_conn, state} ->
            {ClosedSocket, Map.put(state, :close_on_response, true)}
          end)
          |> StreamableHTTPPlug.call(opts)
        after
          Application.put_env(:anubis_mcp, :logging, logging)
        end
      end)

    assert conn.status == 200
    assert Enum.map(events(conn), & &1["params"]["progress"]) == [0, 50, 100]
    assert log =~ "MCP transport event: response_stream_closed"
    assert log =~ "reason: :closed"
  end

  defp call_without_stream(opts, accept) do
    {conn, log} = with_log(fn -> call(opts, %{"progressToken" => "tok"}, accept) end)

    assert log =~ "failed_send_notification"
    assert log =~ ":no_sse_handler"
    assert length(Regex.scan(~r/method: "notifications\/progress"/, log)) == 3
    assert length(Regex.scan(~r/method: "notifications\/tools\/list_changed"/, log)) == 1
    conn
  end

  defp call(opts, extra_meta, accept, tool \\ "progress") do
    opts
    |> request(extra_meta, accept, tool)
    |> StreamableHTTPPlug.call(opts)
  end

  defp request(_opts, extra_meta, accept, tool) do
    meta =
      Map.merge(
        %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientInfo" => %{"name" => "Streamer", "version" => "1.0.0"},
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        extra_meta
      )

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => tool, "arguments" => %{}, "_meta" => meta}
      })

    :post
    |> conn("/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", accept)
    |> put_req_header("mcp-protocol-version", @version)
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", tool)
  end

  defp events(conn) do
    for "data: " <> data <- String.split(chunks(conn), "\n"), do: JSON.decode!(data)
  end

  defp chunks(%Plug.Conn{adapter: {adapter, %{chunks: chunks}}}) when adapter in [Conn, ClosedSocket], do: chunks || ""
end
