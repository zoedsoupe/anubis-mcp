defmodule Anubis.Server.Transport.StreamableHTTP.ResponseStreamTest do
  use Anubis.MCP.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Anubis.Server.Component
  alias Anubis.Server.Registry
  alias Anubis.Server.Supervisor, as: ServerSupervisor
  alias Anubis.Server.Transport.StreamableHTTP
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug
  alias Plug.Adapters.Test.Conn

  @moduletag capture_log: true

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
      Anubis.Server.send_log_message(:info, "working")
      {:reply, Response.text(Response.tool(), "logged"), frame}
    end
  end

  defmodule SlowTool do
    @moduledoc false
    use Component, type: :tool

    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      send(ResponseStreamTest, {:tool_running, self()})

      receive do
        :finish -> {:reply, Response.text(Response.tool(), "finished"), frame}
      end
    end
  end

  defmodule ClosedSocket do
    @moduledoc false
    # The test adapter, except that the client has gone away by the first chunk.
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

    def chunk(_payload, _body), do: {:error, :closed}
  end

  defmodule StreamingServer do
    @moduledoc false
    use Anubis.Server,
      name: "streaming-server",
      version: "1.0.0",
      capabilities: [{:tools, list_changed?: true}],
      protocol_versions: ["2026-07-28"]

    component(ProgressTool, name: "progress")
    component(SlowTool, name: "slow")
    component(LogTool, name: "log")
  end

  setup do
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
    conn = call(opts, %{"progressToken" => "tok"}, "application/json")

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

  defp chunks(%Plug.Conn{adapter: {Conn, %{chunks: chunks}}}), do: chunks || ""
end
