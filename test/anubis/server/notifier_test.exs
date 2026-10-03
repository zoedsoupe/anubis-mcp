defmodule Anubis.Server.NotifierTest do
  @moduledoc """
  `Anubis.Server.Notifier` as a client meets it.

  The helpers read the session pid off the frame instead of `self()`, so a
  tool callback — which runs in a worker process, not the Session — can emit
  notifications the client actually receives. That is the whole contract.
  """
  use Anubis.MCP.Case, async: false

  alias Anubis.Server.Component
  alias Anubis.Server.Notifier
  alias Anubis.Server.Registry
  alias Anubis.Server.Response
  alias Anubis.Server.Session
  alias Anubis.Test.SyncHelpers

  @moduletag capture_log: true

  defmodule ProgressTool do
    @moduledoc false

    use Component, type: :tool

    schema do
    end

    @impl true
    def execute(_params, frame) do
      token = frame.context.request_meta["progressToken"]

      # A task is a different process than the Session and than the callback:
      # the helpers must not depend on either being `self()`.
      Enum.each(1..3, fn step ->
        fn -> Notifier.progress(frame, token, step, total: 3) end
        |> Task.async()
        |> Task.await(1_000)
      end)

      Notifier.tools_list_changed(frame)
      Notifier.log_message(frame, :info, "reindex finished", %{index: "products"})

      {:reply, Response.text(Response.tool(), inspect(token)), frame}
    end
  end

  defmodule ProgressServer do
    @moduledoc false

    use Anubis.Server,
      name: "progress-server",
      version: "1.0.0",
      capabilities: [:tools, :logging, {:tools, list_changed?: true}]

    component(ProgressTool, name: "progress")
  end

  test "a tool callback reaches the client through the frame, from another process" do
    {session, transport, context} = connect(ProgressServer)

    result =
      send_request(session, context, "tools/call", %{
        "name" => "progress",
        "arguments" => %{},
        "_meta" => %{"progressToken" => "tok-1"}
      })

    assert %{"result" => %{"content" => [%{"text" => ~s("tok-1")}]}} = result

    notifications = transport |> StubTransport.get_messages() |> Enum.filter(& &1["method"])

    progress =
      Enum.filter(notifications, &(&1["method"] == "notifications/progress"))

    assert Enum.map(progress, & &1["params"]["progress"]) == [1, 2, 3]
    assert Enum.all?(progress, &(&1["params"]["progressToken"] == "tok-1"))
    assert Enum.all?(progress, &(&1["params"]["total"] == 3))

    assert Enum.any?(notifications, &(&1["method"] == "notifications/tools/list_changed"))

    logs = Enum.filter(notifications, &(&1["method"] == "notifications/log/message"))

    assert [log] = logs
    assert log["params"]["message"] == "reindex finished"
    assert log["params"]["data"] == %{"index" => "products"}
  end

  test "request _meta reaches the tool callback" do
    {session, _transport, context} = connect(ProgressServer)

    assert %{"result" => %{"content" => [%{"text" => ~s(nil)}]}} =
             send_request(session, context, "tools/call", %{"name" => "progress", "arguments" => %{}})
  end

  defp connect(server_module) do
    session_id = "test-#{System.unique_integer([:positive])}"
    transport_name = Registry.transport_name(server_module, StubTransport)
    {:ok, transport} = start_supervised({StubTransport, name: transport_name}, id: transport_name)

    task_sup = Registry.task_supervisor_name(server_module)
    start_supervised({Task.Supervisor, name: task_sup}, id: task_sup)

    session_name = Registry.session_name(server_module, session_id)

    session =
      start_supervised!(
        {Session,
         session_id: session_id,
         server_module: server_module,
         name: session_name,
         transport: [layer: StubTransport, name: transport_name],
         task_supervisor: task_sup},
        id: session_name
      )

    context = %{assigns: %{}}
    request = init_request("2025-03-26", %{"name" => "TestClient", "version" => "1.0.0"})
    {:ok, _} = GenServer.call(session, {:mcp_request, request, context})

    :ok =
      GenServer.cast(
        session,
        {:mcp_notification, build_notification("notifications/initialized", %{}), context}
      )

    SyncHelpers.await_state(session, & &1.initialized)
    StubTransport.clear(transport)

    {session, transport, context}
  end

  defp send_request(session, context, method, params) do
    request = build_request(method, params)
    {:ok, response_json} = GenServer.call(session, {:mcp_request, request, context})
    JSON.decode!(response_json)
  end
end
