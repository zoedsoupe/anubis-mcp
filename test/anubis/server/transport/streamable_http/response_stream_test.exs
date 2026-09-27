defmodule Anubis.Server.Transport.StreamableHTTP.ResponseStreamTest do
  use Anubis.MCP.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Anubis.Server.Registry
  alias Anubis.Server.Supervisor, as: ServerSupervisor
  alias Anubis.Server.Transport.StreamableHTTP
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  @moduletag capture_log: true

  @version "2026-07-28"

  defmodule ProgressTool do
    @moduledoc false
    use Anubis.Server.Component, type: :tool

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

  defmodule StreamingServer do
    @moduledoc false
    use Anubis.Server,
      name: "streaming-server",
      version: "1.0.0",
      capabilities: [{:tools, list_changed?: true}],
      protocol_versions: ["2026-07-28"]

    component(ProgressTool, name: "progress")
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

  defp call(opts, extra_meta, accept) do
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
        "params" => %{"name" => "progress", "arguments" => %{}, "_meta" => meta}
      })

    :post
    |> conn("/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", accept)
    |> put_req_header("mcp-protocol-version", @version)
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", "progress")
    |> StreamableHTTPPlug.call(opts)
  end

  defp events(%Plug.Conn{adapter: {Plug.Adapters.Test.Conn, %{chunks: chunks}}}) do
    for "data: " <> data <- String.split(chunks || "", "\n"), do: JSON.decode!(data)
  end
end
