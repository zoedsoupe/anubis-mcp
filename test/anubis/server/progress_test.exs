defmodule Anubis.Server.ProgressTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.Server.Registry
  alias Anubis.Server.Session

  @moduletag capture_log: true

  defmodule ReportingTool do
    @moduledoc false
    use Anubis.Server.Component, type: :tool

    alias Anubis.Server.Frame
    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      token = Frame.progress_token(frame)
      if token, do: Anubis.Server.send_progress(token, 50, total: 100)
      Anubis.Server.send_tools_list_changed()

      {:reply, Response.json(Response.tool(), %{token: token, meta: Frame.request_meta(frame)}), frame}
    end
  end

  defmodule ProgressServer do
    @moduledoc false
    use Anubis.Server, name: "progress-server", version: "1.0.0", capabilities: [{:tools, list_changed?: true}]

    component(ReportingTool, name: "report")
  end

  setup do
    transport = Registry.transport_name(ProgressServer, StubTransport)
    start_supervised!({StubTransport, name: transport})

    task_sup = Registry.task_supervisor_name(ProgressServer)
    start_supervised!({Task.Supervisor, name: task_sup})

    session =
      start_supervised!(
        {Session,
         session_id: "progress",
         server_module: ProgressServer,
         name: Registry.session_name(ProgressServer, "progress"),
         transport: [layer: StubTransport, name: transport],
         task_supervisor: task_sup}
      )

    {:ok, _} =
      GenServer.call(session, {:mcp_request, init_request("2025-06-18", %{"name" => "t", "version" => "1"}), %{}})

    GenServer.cast(session, {:mcp_notification, build_notification("notifications/initialized"), %{}})
    :sys.get_state(session)
    StubTransport.clear(transport)

    %{session: session, transport: transport}
  end

  test "a tool reads the request's _meta and its progress token", %{session: session} do
    result = call(session, %{"progressToken" => "tok-1"})

    assert %{"token" => "tok-1", "meta" => %{"progressToken" => "tok-1"}} = result
  end

  test "a request without _meta gives an empty map and no token", %{session: session} do
    assert %{"token" => nil, "meta" => %{}} = call(session, nil)
  end

  test "notifications a tool sends reach the transport", %{session: session, transport: transport} do
    call(session, %{"progressToken" => "tok-2"})

    methods = StubTransport.get_messages(transport)

    assert %{"params" => %{"progressToken" => "tok-2", "progress" => 50, "total" => 100}} =
             Enum.find(methods, &(&1["method"] == "notifications/progress"))

    assert Enum.any?(methods, &(&1["method"] == "notifications/tools/list_changed"))
  end

  defp call(session, meta) do
    params = %{"name" => "report", "arguments" => %{}}
    params = if meta, do: Map.put(params, "_meta", meta), else: params

    request = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "tools/call",
      "params" => params
    }

    {:ok, response} = GenServer.call(session, {:mcp_request, request, %{}})
    %{"result" => %{"content" => [%{"text" => text}]}} = JSON.decode!(response)
    JSON.decode!(text)
  end
end
