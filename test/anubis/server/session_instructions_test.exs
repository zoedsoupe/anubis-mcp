defmodule Anubis.Server.SessionInstructionsTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.Server.Registry
  alias Anubis.Server.Session

  @moduletag capture_log: true

  defmodule InstructionsViaOptionServer do
    @moduledoc false

    use Anubis.Server,
      name: "instructions-option-server",
      version: "1.0.0",
      capabilities: [:tools],
      instructions: "Use this server to look up user accounts. Always confirm before deleting."
  end

  defmodule InstructionsViaCallbackServer do
    @moduledoc false

    use Anubis.Server,
      name: "instructions-callback-server",
      version: "1.0.0",
      capabilities: [:tools]

    @impl Anubis.Server
    def server_instructions do
      "Dynamic instructions from callback"
    end
  end

  defmodule NoInstructionsServer do
    @moduledoc false

    use Anubis.Server,
      name: "no-instructions-server",
      version: "1.0.0",
      capabilities: [:tools]
  end

  defmodule InstructionsPerConnectionServer do
    @moduledoc false

    use Anubis.Server,
      name: "instructions-per-connection-server",
      version: "1.0.0",
      capabilities: [:tools]

    @impl Anubis.Server
    def server_instructions, do: "Static fallback"

    @impl Anubis.Server
    def server_instructions(frame) do
      case frame.assigns[:audience] do
        nil -> "Instructions for an unknown caller"
        audience -> "Instructions for #{audience}"
      end
    end
  end

  describe "instructions via use option" do
    test "initialize response includes instructions" do
      {session, _transport} = start_session(InstructionsViaOptionServer)

      result = send_initialize(session)

      assert result["instructions"] ==
               "Use this server to look up user accounts. Always confirm before deleting."
    end

    test "server_instructions/0 returns the configured value" do
      assert InstructionsViaOptionServer.server_instructions() ==
               "Use this server to look up user accounts. Always confirm before deleting."
    end
  end

  describe "instructions via callback override" do
    test "initialize response includes instructions from callback" do
      {session, _transport} = start_session(InstructionsViaCallbackServer)

      result = send_initialize(session)

      assert result["instructions"] == "Dynamic instructions from callback"
    end

    test "server_instructions/0 returns the callback value" do
      assert InstructionsViaCallbackServer.server_instructions() ==
               "Dynamic instructions from callback"
    end
  end

  describe "no instructions" do
    test "initialize response omits instructions field" do
      {session, _transport} = start_session(NoInstructionsServer)

      result = send_initialize(session)

      refute Map.has_key?(result, "instructions")
    end

    test "server_instructions/0 returns nil" do
      assert NoInstructionsServer.server_instructions() == nil
    end
  end

  describe "instructions per connection" do
    test "the frame's assigns decide what the handshake answers with" do
      {session, _transport} = start_session(InstructionsPerConnectionServer)

      result = send_initialize(session, %{assigns: %{audience: "a support agent"}})

      assert result["instructions"] == "Instructions for a support agent"
    end

    test "a connection carrying no assigns still gets an answer" do
      {session, _transport} = start_session(InstructionsPerConnectionServer)

      assert send_initialize(session)["instructions"] == "Instructions for an unknown caller"
    end

    test "arity 1 takes precedence over arity 0" do
      {session, _transport} = start_session(InstructionsPerConnectionServer)

      refute send_initialize(session)["instructions"] == "Static fallback"
    end

    test "a server defining only arity 0 is unaffected" do
      {session, _transport} = start_session(InstructionsViaCallbackServer)

      assert send_initialize(session)["instructions"] == "Dynamic instructions from callback"
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
