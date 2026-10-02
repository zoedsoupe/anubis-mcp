defmodule Anubis.Server.CacheHintsTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.Server.Component
  alias Anubis.Server.Registry
  alias Anubis.Server.Session
  alias Anubis.Server.Stateless

  @moduletag capture_log: true

  @version "2026-07-28"

  defmodule ConfirmTool do
    @moduledoc false
    use Component, type: :tool

    alias Anubis.Server.Frame
    alias Anubis.Server.InputRequired
    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      if Frame.input_response(frame, "ok"),
        do: {:reply, Response.text(Response.tool(), "done"), frame},
        else: {:reply, InputRequired.elicit(InputRequired.new(), "ok", "Sure?", %{"type" => "object"}), frame}
    end
  end

  defmodule NoteResource do
    @moduledoc false
    use Component, type: :resource, uri: "notes://one", mime_type: "text/plain"

    alias Anubis.Server.Frame
    alias Anubis.Server.InputRequired
    alias Anubis.Server.Response

    @impl true
    def read(_params, frame) do
      if Frame.input_response(frame, "ok"),
        do: {:reply, Response.text(Response.resource(), "note"), frame},
        else: {:reply, InputRequired.elicit(InputRequired.new(), "ok", "Sure?", %{"type" => "object"}), frame}
    end
  end

  defmodule DefaultServer do
    @moduledoc false
    use Anubis.Server,
      name: "default-hints",
      version: "1.0.0",
      capabilities: [:tools, :resources],
      protocol_versions: ["2026-07-28", "2025-11-25"]

    component(ConfirmTool, name: "confirm")
    component(NoteResource, name: "note")
  end

  defmodule HintingServer do
    @moduledoc false
    use Anubis.Server,
      name: "hinting",
      version: "1.0.0",
      capabilities: [:tools, :resources],
      protocol_versions: ["2026-07-28"]

    component(ConfirmTool, name: "confirm")
    component(NoteResource, name: "note")

    @impl true
    def cache_hints("tools/list"), do: %{ttl_ms: 60_000, scope: :public}
    def cache_hints(_method), do: %{ttl_ms: 5_000, scope: :private}
  end

  defmodule OwnHintsServer do
    @moduledoc false
    use Anubis.Server,
      name: "own-hints",
      version: "1.0.0",
      capabilities: [:resources],
      protocol_versions: ["2026-07-28"]

    @impl true
    def handle_request(%{"method" => "resources/read"}, frame) do
      {:reply, %{"contents" => [%{"uri" => "notes://own", "text" => "own"}], "ttlMs" => 60_000}, frame}
    end
  end

  defmodule BrokenServer do
    @moduledoc false
    use Anubis.Server,
      name: "broken-hints",
      version: "1.0.0",
      capabilities: [:tools],
      protocol_versions: ["2026-07-28"]

    component(ConfirmTool, name: "confirm")

    @impl true
    def cache_hints(_method), do: %{ttl_ms: -1, scope: :everyone}
  end

  test "every cacheable result carries conservative hints by default" do
    session = start_session(DefaultServer)

    for {method, params} <- [
          {"server/discover", %{}},
          {"tools/list", %{}},
          {"resources/list", %{}},
          {"resources/templates/list", %{}}
        ] do
      assert %{"ttlMs" => 0, "cacheScope" => "private"} = result(session, method, params), method
    end
  end

  test "the server's cache_hints/1 decides them per method" do
    session = start_session(HintingServer)

    assert %{"ttlMs" => 60_000, "cacheScope" => "public"} = result(session, "tools/list")
    assert %{"ttlMs" => 5_000, "cacheScope" => "private"} = result(session, "server/discover")

    read = %{"uri" => "notes://one", "inputResponses" => %{"ok" => %{"action" => "accept"}}}
    assert %{"ttlMs" => 0, "cacheScope" => "private"} = result(session, "resources/read", read)
  end

  test "an input-required result and a non-cacheable method carry none" do
    session = start_session(HintingServer)

    input_required = result(session, "resources/read", %{"uri" => "notes://one"})
    assert input_required["resultType"] == "input_required"
    refute Map.has_key?(input_required, "ttlMs")

    call = result(session, "tools/call", %{"name" => "confirm", "inputResponses" => %{"ok" => %{}}})
    assert call["resultType"] == "complete"
    refute Map.has_key?(call, "ttlMs")
    refute Map.has_key?(call, "cacheScope")
  end

  test "handshake-era results are left as they were" do
    session = start_session(DefaultServer)
    init = init_request("2025-11-25", %{"name" => "Legacy", "version" => "1.0.0"})
    {:ok, _} = GenServer.call(session, {:mcp_request, init, %{}})
    GenServer.cast(session, {:mcp_notification, build_notification("notifications/initialized"), %{}})
    :sys.get_state(session)

    message = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}}
    {:ok, response} = GenServer.call(session, {:mcp_request, message, %{}})

    result = JSON.decode!(response)["result"]
    refute Map.has_key?(result, "ttlMs")
    refute Map.has_key?(result, "resultType")
  end

  test "a handler keeps its own TTL, except on a retry" do
    session = start_session(OwnHintsServer)

    assert %{"ttlMs" => 60_000} = result(session, "resources/read", %{"uri" => "notes://own"})

    retry = %{"uri" => "notes://own", "inputResponses" => %{"ok" => %{"action" => "accept"}}}
    assert %{"ttlMs" => 0, "cacheScope" => "private"} = result(session, "resources/read", retry)
  end

  test "hints outside the contract fail loudly" do
    assert_raise ArgumentError, ~r/cache_hints/, fn ->
      Stateless.cache_hints(BrokenServer, "tools/list", false)
    end
  end

  defp result(session, method, params \\ %{}) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientInfo" => %{"name" => "Tester", "version" => "1.0.0"},
      "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
    }

    message = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => Map.put(params, "_meta", meta)}
    {:ok, response} = GenServer.call(session, {:mcp_request, message, %{}})
    assert %{"result" => result} = JSON.decode!(response)
    result
  end

  defp start_session(server) do
    session_id = "hints-#{System.unique_integer([:positive])}"
    transport_name = Registry.transport_name(server, StubTransport)
    start_supervised({StubTransport, name: transport_name}, id: transport_name)

    task_sup = Registry.task_supervisor_name(server)
    start_supervised({Task.Supervisor, name: task_sup}, id: task_sup)

    start_supervised!(
      {Session,
       session_id: session_id,
       server_module: server,
       name: Registry.session_name(server, session_id),
       transport: [layer: StubTransport, name: transport_name],
       task_supervisor: task_sup},
      id: session_id
    )
  end
end
