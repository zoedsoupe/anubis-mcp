defmodule Anubis.Server.StatelessTest do
  use Anubis.MCP.Case, async: false

  import ExUnit.CaptureLog

  alias Anubis.Protocol.Registry, as: ProtocolRegistry
  alias Anubis.Protocol.Schema
  alias Anubis.Protocol.V2026_07_28
  alias Anubis.Server.Registry
  alias Anubis.Server.Session
  alias Anubis.Server.Stateless

  @moduletag capture_log: true

  doctest Stateless

  @stateless_version "2026-07-28"
  @client_info %{"name" => "StatelessProbe", "version" => "1.0.0"}

  defmodule EchoContextTool do
    @moduledoc false

    use Anubis.Server.Component, type: :tool

    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      {:reply, Response.json(Response.tool(), %{capabilities: frame.context.client_capabilities}), frame}
    end
  end

  defmodule DualEraServer do
    @moduledoc false

    use Anubis.Server,
      name: "dual-era-server",
      version: "1.0.0",
      capabilities: [:tools, :resources, :logging],
      protocol_versions: ["2026-07-28", "2025-11-25"],
      instructions: "Serves both eras."

    component(EchoContextTool)
  end

  defmodule StatelessOnlyServer do
    @moduledoc false

    use Anubis.Server,
      name: "stateless-only-server",
      version: "1.0.0",
      capabilities: [:tools],
      protocol_versions: ["2026-07-28"]
  end

  describe "server/discover" do
    test "advertises the stateless versions, filtered capabilities and identity" do
      session = start_session(DualEraServer)

      result = request!(session, "server/discover")

      assert result["resultType"] == "complete"
      assert result["supportedVersions"] == [@stateless_version]
      assert result["instructions"] == "Serves both eras."
      assert result["ttlMs"] >= 0
      assert result["cacheScope"] in ["public", "private"]

      assert result["_meta"][Stateless.server_info_key()] == %{
               "name" => "dual-era-server",
               "version" => "1.0.0"
             }
    end

    test "the result validates against the dialect's result schema" do
      session = start_session(DualEraServer)

      result = request!(session, "server/discover")
      schema = V2026_07_28.request_result_schema("server/discover")

      assert {:ok, _} = Peri.validate(schema, result)
    end

    test "omits the versions the server can only serve through the handshake" do
      session = start_session(DualEraServer)

      result = request!(session, "server/discover")

      for legacy <- ProtocolRegistry.legacy_versions() do
        refute legacy in result["supportedVersions"]
      end
    end

    test "capabilities are filtered by the dialect that served the request" do
      session = start_session(DualEraServer)

      result = request!(session, "server/discover")
      capabilities = result["capabilities"]

      assert Map.has_key?(capabilities, "tools")
      assert capabilities == V2026_07_28.server_capabilities(DualEraServer.server_capabilities())
    end
  end

  describe "protocol version admission" do
    test "a version the server does not serve is rejected with -32022" do
      session = start_session(DualEraServer)

      error = error!(session, "server/discover", protocol_version: "1900-01-01")

      assert error["code"] == -32_022
      assert error["data"]["requested"] == "1900-01-01"
      assert error["data"]["supported"] == [@stateless_version]
    end

    test "a stateless request is served without an initialize handshake" do
      session = start_session(DualEraServer)

      refute :sys.get_state(session).initialized

      assert %{"resultType" => "complete"} = request!(session, "server/discover")
    end

    test "the handshake still negotiates a legacy version on the same server" do
      session = start_session(DualEraServer)

      result = initialize!(session, "2025-11-25")

      assert result["protocolVersion"] == "2025-11-25"
      refute Map.has_key?(result, "resultType")
    end
  end

  describe "per-request client metadata" do
    test "capabilities reach the handler and never outlive the request" do
      session = start_session(DualEraServer)

      first = call_echo_tool(session, %{"elicitation" => %{}})
      second = call_echo_tool(session, %{})

      assert first == %{"capabilities" => %{"elicitation" => %{}}}
      assert second == %{"capabilities" => %{}}

      state = :sys.get_state(session)
      assert is_nil(state.client_capabilities)
      assert is_nil(state.client_info)
      assert is_nil(state.protocol_module)
    end
  end

  describe "result shaping" do
    test "every stateless result carries resultType and the server identity" do
      session = start_session(DualEraServer)

      result = request!(session, "tools/list")

      assert result["resultType"] == "complete"
      assert result["_meta"][Stateless.server_info_key()] == DualEraServer.server_info()
    end

    test "legacy results are left untouched" do
      session = start_session(DualEraServer)
      initialize!(session, "2025-11-25")

      result = request!(session, "tools/list", era: :legacy)

      refute Map.has_key?(result, "resultType")
      refute Map.has_key?(result, "_meta")
    end
  end

  describe "resource not found" do
    test "the stateless era reports it as invalid params" do
      session = start_session(DualEraServer)

      error = error!(session, "resources/read", params: %{"uri" => "file:///missing.txt"})

      assert error["code"] == -32_602
    end

    test "the legacy era keeps the code it shipped with" do
      session = start_session(DualEraServer)
      initialize!(session, "2025-11-25")

      error = error!(session, "resources/read", params: %{"uri" => "file:///missing.txt"}, era: :legacy)

      assert error["code"] == -32_002
    end
  end

  describe "server-initiated requests" do
    test "are refused with the missing-capability error the revision reserves" do
      session = start_session(DualEraServer)

      log =
        capture_log(fn ->
          send(session, {:send_roots_request, 1_000})
          :sys.get_state(session)
        end)

      assert log =~ "missing_required_client_capability"
      assert :sys.get_state(session).server_requests == %{}
    end
  end

  describe "a server that declares no legacy version" do
    test "answers initialize with -32022 instead of crashing" do
      session = start_session(StatelessOnlyServer)

      request = init_request("2025-11-25", @client_info)
      {:ok, response} = GenServer.call(session, {:mcp_request, request, %{}})

      assert %{"error" => error} = JSON.decode!(response)
      assert error["code"] == -32_022
      assert error["data"]["supported"] == [@stateless_version]
      assert Process.alive?(session)
    end
  end

  defp start_session(server_module) do
    session_id = "stateless-#{System.unique_integer([:positive])}"
    transport_name = Registry.transport_name(server_module, StubTransport)
    start_supervised!({StubTransport, name: transport_name}, id: transport_name)

    task_sup = Registry.task_supervisor_name(server_module)
    start_supervised!({Task.Supervisor, name: task_sup}, id: task_sup)

    session_name = Registry.session_name(server_module, session_id)

    start_supervised!(
      {Session,
       session_id: session_id,
       server_module: server_module,
       name: session_name,
       transport: [layer: StubTransport, name: transport_name],
       task_supervisor: task_sup},
      id: session_name
    )
  end

  defp initialize!(session, version) do
    request = init_request(version, @client_info)
    {:ok, response} = GenServer.call(session, {:mcp_request, request, %{}})

    GenServer.cast(session, {:mcp_notification, build_notification("notifications/initialized"), %{}})
    sync_session(session)

    JSON.decode!(response)["result"]
  end

  defp call_echo_tool(session, capabilities) do
    params = %{"name" => "echo_context_tool", "arguments" => %{}}
    result = request!(session, "tools/call", params: params, capabilities: capabilities)

    result["content"] |> hd() |> Map.fetch!("text") |> JSON.decode!()
  end

  defp request!(session, method, opts \\ []) do
    response = dispatch(session, method, opts)
    assert %{"result" => result} = response
    result
  end

  defp error!(session, method, opts) do
    response = dispatch(session, method, opts)
    assert %{"error" => error} = response
    error
  end

  defp dispatch(session, method, opts) do
    request = build_request(method, request_params(method, opts))
    {:ok, response} = GenServer.call(session, {:mcp_request, request, %{}})
    JSON.decode!(response)
  end

  defp request_params(_method, opts) do
    params = Keyword.get(opts, :params, %{})

    case Keyword.get(opts, :era, :stateless) do
      :legacy -> params
      :stateless -> Map.put(params, "_meta", request_meta(opts))
    end
  end

  defp request_meta(opts) do
    %{
      Schema.protocol_version_key() => Keyword.get(opts, :protocol_version, @stateless_version),
      "io.modelcontextprotocol/clientCapabilities" => Keyword.get(opts, :capabilities, %{}),
      "io.modelcontextprotocol/clientInfo" => @client_info
    }
  end

  defp sync_session(session), do: :sys.get_state(session)
end
