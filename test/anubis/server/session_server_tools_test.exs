defmodule Anubis.Server.SessionServerToolsTest do
  @moduledoc """
  `server_tools/2` over the protocol path, as a client meets it.

  `Anubis.Server.HandlersServerToolsTest` covers the callback's contract against
  `Handlers.handle/3`. This file answers the question that one cannot: whether the surface a
  *session* serves follows the frame of the request being answered, through `initialize`, the
  acknowledgement, and the two methods that read the tool list.
  """
  use Anubis.MCP.Case, async: false

  alias Anubis.Server.Component
  alias Anubis.Server.Registry
  alias Anubis.Server.Response
  alias Anubis.Server.Session
  alias Anubis.Test.SyncHelpers

  @moduletag capture_log: true

  defmodule ReadTool do
    @moduledoc "Reads one record."

    use Component, type: :tool

    schema do
    end

    @impl true
    def execute(_params, frame), do: {:reply, Response.text(Response.tool(), "read"), frame}
  end

  defmodule BulkExportTool do
    @moduledoc "Exports every record at once."

    use Component, type: :tool

    schema do
    end

    @impl true
    def execute(_params, frame), do: {:reply, Response.text(Response.tool(), "exported"), frame}
  end

  defmodule TieredServer do
    @moduledoc false

    use Anubis.Server,
      name: "tiered-server",
      version: "1.0.0",
      capabilities: [:tools]

    component(ReadTool, name: "read")
    component(BulkExportTool, name: "bulk_export")

    @impl Anubis.Server
    def server_tools(tools, frame) do
      case frame.assigns[:plan] do
        :enterprise ->
          tools

        _other ->
          tools
          |> Enum.reject(&(&1.name == "bulk_export"))
          |> Enum.map(&%{&1 | description: "Reads a record. One at a time."})
      end
    end
  end

  defmodule PlainServer do
    @moduledoc false

    use Anubis.Server,
      name: "plain-server",
      version: "1.0.0",
      capabilities: [:tools]

    component(ReadTool, name: "read")
    component(BulkExportTool, name: "bulk_export")
  end

  describe "a server that does not export the callback" do
    test "serves a session its registered tools, unchanged" do
      session = connect(PlainServer)

      assert ["bulk_export", "read"] = session |> list_tools() |> Enum.map(& &1["name"]) |> Enum.sort()
    end
  end

  describe "a server that does export it" do
    test "the connection's assigns decide the tools its session lists" do
      enterprise = connect(TieredServer, %{plan: :enterprise})
      free = connect(TieredServer, %{plan: :free})

      assert "bulk_export" in Enum.map(list_tools(enterprise), & &1["name"])
      refute "bulk_export" in Enum.map(list_tools(free), & &1["name"])
    end

    test "a tool withheld from a connection cannot be called by name either" do
      # The list and the call resolve through the same function, so withholding is not merely
      # cosmetic — which is what makes this the protocol-level statement of the contract.
      assert %{"error" => error} = call_tool(connect(TieredServer, %{plan: :free}), "bulk_export")
      assert error["data"]["message"] == "Tool not found: bulk_export"

      assert %{"result" => result} =
               call_tool(connect(TieredServer, %{plan: :enterprise}), "bulk_export")

      assert [%{"text" => "exported"}] = result["content"]
    end

    test "a tool may reach a connection rewritten rather than withheld" do
      [read] = list_tools(connect(TieredServer, %{plan: :free}))

      assert read["description"] == "Reads a record. One at a time."

      assert %{"description" => "Reads one record."} =
               TieredServer
               |> connect(%{plan: :enterprise})
               |> list_tools()
               |> Enum.find(&(&1["name"] == "read"))
    end
  end

  # Helpers

  # The assigns ride on every request, not only the handshake: the frame a method is answered
  # with is built from the transport context of *that* request.
  defp connect(server_module, assigns \\ %{}) do
    session_id = "test-#{System.unique_integer([:positive])}"
    transport_name = Registry.transport_name(server_module, StubTransport)
    start_once({StubTransport, name: transport_name}, transport_name)

    task_sup = Registry.task_supervisor_name(server_module)
    start_once({Task.Supervisor, name: task_sup}, task_sup)

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

    context = %{assigns: assigns}
    request = init_request("2025-03-26", %{"name" => "TestClient", "version" => "1.0.0"})
    {:ok, _} = GenServer.call(session, {:mcp_request, request, context})

    :ok =
      GenServer.cast(
        session,
        {:mcp_notification, build_notification("notifications/initialized", %{}), context}
      )

    SyncHelpers.await_state(session, & &1.initialized)

    {session, context}
  end

  # Two connections in one test share a server module, and the transport and task supervisor
  # are named after it.
  defp start_once(spec, id) do
    case start_supervised(spec, id: id) do
      {:ok, pid} -> pid
      {:error, {{:already_started, pid}, _}} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp list_tools(connection), do: send_request(connection, "tools/list")["result"]["tools"]

  defp call_tool(connection, name) do
    send_request(connection, "tools/call", %{"name" => name, "arguments" => %{}})
  end

  defp send_request({session, context}, method, params \\ %{}) do
    request = build_request(method, params)
    {:ok, response_json} = GenServer.call(session, {:mcp_request, request, context})
    JSON.decode!(response_json)
  end
end
