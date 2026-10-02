defmodule Anubis.Server.SessionServerInfoTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.Server.Registry
  alias Anubis.Server.Session

  @moduletag capture_log: true

  defmodule ServerInfoWithIcons do
    @moduledoc false

    use Anubis.Server,
      name: "server-info-with-icons",
      version: "1.0.0",
      capabilities: [:tools],
      icons: [
        %{src: "https://example.com/server.png", mimeType: "image/png", sizes: ["48x48"]}
      ],
      website_url: "https://example.com"
  end

  defmodule ServerInfoWithoutIcons do
    @moduledoc false

    use Anubis.Server,
      name: "server-info-without-icons",
      version: "1.0.0",
      capabilities: [:tools]
  end

  describe "implementation icons and websiteUrl" do
    test "server_info includes icons and websiteUrl from use options" do
      info = ServerInfoWithIcons.server_info()

      assert info["name"] == "server-info-with-icons"
      assert info["version"] == "1.0.0"
      assert info["websiteUrl"] == "https://example.com"

      assert info["icons"] == [
               %{src: "https://example.com/server.png", mimeType: "image/png", sizes: ["48x48"]}
             ]
    end

    test "server_info omits icons and websiteUrl when not configured" do
      info = ServerInfoWithoutIcons.server_info()

      assert info == %{"name" => "server-info-without-icons", "version" => "1.0.0"}
    end

    test "initialize response includes icons and websiteUrl in serverInfo" do
      {session, _transport} = start_session(ServerInfoWithIcons)

      result = send_initialize(session)

      assert result["serverInfo"]["websiteUrl"] == "https://example.com"

      assert result["serverInfo"]["icons"] == [
               %{
                 "src" => "https://example.com/server.png",
                 "mimeType" => "image/png",
                 "sizes" => ["48x48"]
               }
             ]
    end

    test "initialize response omits icons and websiteUrl when not configured" do
      {session, _transport} = start_session(ServerInfoWithoutIcons)

      result = send_initialize(session)

      refute Map.has_key?(result["serverInfo"], "icons")
      refute Map.has_key?(result["serverInfo"], "websiteUrl")
    end
  end

  # Helpers

  defp start_session(server_module) do
    session_id = "test-#{System.unique_integer([:positive])}"
    transport_name = Registry.transport_name(server_module, StubTransport)
    transport = start_supervised!({StubTransport, name: transport_name}, id: transport_name)

    task_sup = Registry.task_supervisor_name(server_module)
    start_supervised!({Task.Supervisor, name: task_sup}, id: task_sup)

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

    {session, transport}
  end

  defp send_initialize(session, transport_context \\ %{}) do
    request = init_request("2025-03-26", %{"name" => "TestClient", "version" => "1.0.0"})
    {:ok, response_json} = GenServer.call(session, {:mcp_request, request, transport_context})
    response = JSON.decode!(response_json)
    response["result"]
  end
end
