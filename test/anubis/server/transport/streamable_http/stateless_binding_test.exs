defmodule Anubis.Server.Transport.StreamableHTTP.StatelessBindingTest do
  use Anubis.MCP.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Anubis.Server.Registry
  alias Anubis.Server.Session
  alias Anubis.Server.Supervisor, as: ServerSupervisor
  alias Anubis.Server.Transport.StreamableHTTP
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug
  alias Anubis.Server.Transport.StreamableHTTP.StatelessBinding

  @moduletag capture_log: true

  doctest StatelessBinding

  @version "2026-07-28"
  @client_info %{"name" => "BindingProbe", "version" => "1.0.0"}

  defmodule WhoAmITool do
    @moduledoc false

    use Anubis.Server.Component, type: :tool

    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      identity = %{
        initialized_for: frame.assigns[:initialized_for],
        user: frame.assigns[:user],
        leaked: frame.assigns[:leaked],
        client: frame.context.client_info["name"]
      }

      {:reply, Response.json(Response.tool(), identity), frame}
    end
  end

  defmodule DualEraServer do
    @moduledoc false

    use Anubis.Server,
      name: "dual-era-http",
      version: "1.0.0",
      capabilities: [:tools],
      protocol_versions: ["2026-07-28", "2025-11-25"]

    alias Anubis.Server.Frame

    component(WhoAmITool)

    @impl true
    def init(client_info, frame) when is_map(client_info),
      do: {:ok, Frame.assign(frame, :initialized_for, client_info["name"])}
  end

  setup do
    server = DualEraServer

    task_sup = Registry.task_supervisor_name(server)
    start_supervised!({Task.Supervisor, name: task_sup})

    stub_transport = Registry.transport_name(server, StubTransport)
    start_supervised!({StubTransport, name: stub_transport})

    registry_name = Registry.registry_name(server)
    start_supervised!({Registry.Local, name: registry_name})
    start_supervised!({Elixir.Registry, keys: :unique, name: Registry.naming_registry_name(registry_name)})

    session_sup = Registry.session_supervisor_name(server)
    start_supervised!({DynamicSupervisor, name: session_sup, strategy: :one_for_one})

    :persistent_term.put({ServerSupervisor, server, :session_config}, %{
      server_module: server,
      registry_mod: Registry.Local,
      transport: [layer: StubTransport, name: stub_transport],
      session_idle_timeout: nil,
      timeout: 30_000,
      task_supervisor: task_sup
    })

    on_exit(fn -> :persistent_term.erase({ServerSupervisor, server, :session_config}) end)

    http_transport = Registry.transport_name(server, :streamable_http)
    start_supervised!({StreamableHTTP, server: server, name: http_transport, task_supervisor: task_sup})

    %{opts: StreamableHTTPPlug.init(server: server), session_sup: session_sup}
  end

  describe "server/discover" do
    test "is answered without a session", %{opts: opts} do
      conn = post_stateless(opts, "server/discover")

      assert conn.status == 200
      assert get_resp_header(conn, "mcp-session-id") == []

      result = JSON.decode!(conn.resp_body)["result"]
      assert result["resultType"] == "complete"
      assert result["supportedVersions"] == [@version]
    end
  end

  describe "a body a parser already decoded" do
    test "is validated against the version it declares", %{opts: opts} do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => %{"_meta" => meta(@client_info)}}

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", @version)
        |> put_req_header("mcp-method", "server/discover")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["result"]["supportedVersions"] == [@version]
    end

    test "is a batch when Plug.Parsers put an array under _json", %{opts: opts} do
      message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => %{}}

      :post
      |> conn("/", %{"_json" => [message]})
      |> stateless_headers()
      |> StreamableHTTPPlug.call(opts)
      |> assert_batch_refused()
    end
  end

  describe "the Accept header" do
    test "a client that marks application/json unacceptable gets a 406", %{opts: opts} do
      conn = post_tool_call(opts, headers: [{"accept", "application/json;q=0, text/event-stream"}])

      assert conn.status == 406
    end

    test "a quality above zero and a second Accept line are honored", %{opts: opts} do
      conn =
        [headers: [{"accept", "text/event-stream"}]]
        |> tool_call_conn()
        |> Plug.Conn.prepend_req_headers([{"accept", "Application/JSON; q=0.5"}])
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 200
    end
  end

  describe "a batch" do
    test "is a 400 with -32600", %{opts: opts} do
      body = JSON.encode!([%{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => %{}}])

      :post
      |> conn("/", body)
      |> put_req_header("content-type", "application/json")
      |> stateless_headers()
      |> StreamableHTTPPlug.call(opts)
      |> assert_batch_refused()
    end
  end

  describe "tools/call" do
    test "runs init/2 with the request's client info and the connection's assigns", %{opts: opts} do
      identity = call_who_am_i(opts, assigns: %{user: "alice"})

      assert identity == %{
               "initialized_for" => "BindingProbe",
               "user" => "alice",
               "leaked" => nil,
               "client" => "BindingProbe"
             }
    end

    test "runs init/2 with an empty map when the request declares no client info", %{opts: opts} do
      assert %{"initialized_for" => nil, "client" => nil} = call_who_am_i(opts, client_info: nil)
    end

    test "keeps one request's assigns and client info out of the next", %{opts: opts} do
      call_who_am_i(opts, assigns: %{leaked: true})

      identity = call_who_am_i(opts, client_info: %{"name" => "Second", "version" => "1.0.0"})

      assert identity["leaked"] == nil
      assert identity["client"] == "Second"
      assert identity["initialized_for"] == "Second"
    end

    test "leaves no session behind", %{opts: opts, session_sup: session_sup} do
      call_who_am_i(opts)

      assert DynamicSupervisor.count_children(session_sup).active == 0
    end

    test "ignores an Mcp-Session-Id header", %{opts: opts} do
      conn = post_tool_call(opts, headers: [{"mcp-session-id", "not-a-session"}])

      assert conn.status == 200
      assert get_resp_header(conn, "mcp-session-id") == []
    end

    test "accepts an Mcp-Name in the base64 sentinel form", %{opts: opts} do
      encoded = "=?base64?" <> Base.encode64("who_am_i_tool") <> "?="
      conn = post_tool_call(opts, headers: [{"mcp-name", encoded}])

      assert conn.status == 200
    end
  end

  describe "header validation" do
    test "rejects a request without Mcp-Method", %{opts: opts} do
      conn = post_tool_call(opts, drop_headers: ["mcp-method"])

      assert_header_mismatch(conn, "mcp-method")
    end

    test "rejects an Mcp-Method that disagrees with the body", %{opts: opts} do
      conn = post_tool_call(opts, headers: [{"mcp-method", "tools/list"}])

      assert_header_mismatch(conn, "mcp-method")
    end

    test "rejects a tools/call without Mcp-Name", %{opts: opts} do
      conn = post_tool_call(opts, drop_headers: ["mcp-name"])

      assert_header_mismatch(conn, "mcp-name")
    end

    test "rejects an Mcp-Name that disagrees with the body", %{opts: opts} do
      conn = post_tool_call(opts, headers: [{"mcp-name", "another_tool"}])

      assert_header_mismatch(conn, "mcp-name")
    end

    test "answers a request without _meta with -32602 and its id", %{opts: opts} do
      body = %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/call", "params" => %{"name" => "who_am_i_tool"}}

      conn = post_raw(opts, body, [{"mcp-method", "tools/call"}, {"mcp-name", "who_am_i_tool"}])

      assert conn.status == 400
      assert %{"id" => 7, "error" => %{"code" => -32_602}} = JSON.decode!(conn.resp_body)
    end

    test "answers a _meta without clientCapabilities with -32602 and its id", %{opts: opts} do
      meta = %{
        "io.modelcontextprotocol/protocolVersion" => @version,
        "io.modelcontextprotocol/clientInfo" => @client_info
      }

      body = %{"jsonrpc" => "2.0", "id" => 8, "method" => "server/discover", "params" => %{"_meta" => meta}}

      conn = post_raw(opts, body, [{"mcp-method", "server/discover"}])

      assert conn.status == 400
      assert %{"id" => 8, "error" => %{"code" => -32_602}} = JSON.decode!(conn.resp_body)
    end

    test "still answers a complete _meta naming another version with a header mismatch", %{opts: opts} do
      meta = %{meta(@client_info) | "io.modelcontextprotocol/protocolVersion" => "2099-01-01"}
      body = %{"jsonrpc" => "2.0", "id" => 9, "method" => "server/discover", "params" => %{"_meta" => meta}}

      conn = post_raw(opts, body, [{"mcp-method", "server/discover"}])

      assert_header_mismatch(conn, "MCP-Protocol-Version")
      assert JSON.decode!(conn.resp_body)["id"] == 9
    end
  end

  describe "status codes" do
    test "a method this revision removed is a 404 with -32601", %{opts: opts} do
      conn = post_stateless(opts, "ping")

      assert conn.status == 404
      assert %{"id" => 1, "error" => %{"code" => -32_601}} = JSON.decode!(conn.resp_body)
    end

    test "an unserved version is a 400 with -32022 naming the stateless versions", %{opts: opts} do
      body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 3, "method" => "server/discover", "params" => %{}})

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", "2099-01-01")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 400
      response = JSON.decode!(conn.resp_body)
      assert response["id"] == 3
      assert response["error"]["code"] == -32_022
      assert response["error"]["data"]["supported"] == [@version]
      assert response["error"]["data"]["requested"] == "2099-01-01"
    end

    test "a notification is accepted with an empty 202", %{opts: opts} do
      body = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => %{"requestId" => 1}})

      conn =
        body
        |> stateless_conn([{"mcp-method", "notifications/cancelled"}])
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "GET and DELETE are 405 with Allow: POST", %{opts: opts} do
      for method <- [:get, :delete] do
        conn =
          method
          |> conn("/")
          |> put_req_header("accept", "application/json, text/event-stream")
          |> put_req_header("mcp-protocol-version", @version)
          |> StreamableHTTPPlug.call(opts)

        assert conn.status == 405
        assert get_resp_header(conn, "allow") == ["POST"]
      end
    end
  end

  describe "the legacy era on the same endpoint" do
    test "initialize still opens a session", %{opts: opts} do
      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25", "clientInfo" => @client_info, "capabilities" => %{}}
        })

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 200
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
      assert JSON.decode!(conn.resp_body)["result"]["protocolVersion"] == "2025-11-25"
    end
  end

  describe "a session with an owner" do
    test "stops when its owner exits", %{session_sup: _session_sup} do
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      config = ServerSupervisor.get_session_config(DualEraServer)

      {:ok, session} =
        ServerSupervisor.start_session(DualEraServer,
          session_id: "owned",
          server_module: DualEraServer,
          transport: config.transport,
          task_supervisor: config.task_supervisor,
          owner: owner
        )

      ref = Process.monitor(session)
      # The owner's DOWN reaches the session on its own path, so the monitor is
      # made to land first: signals from this process to the session stay ordered.
      :sys.get_state(session)
      send(owner, :stop)

      assert_receive {:DOWN, ^ref, :process, ^session, :shutdown}
    end

    test "a session without one does not run init/2 for stateless requests" do
      config = ServerSupervisor.get_session_config(DualEraServer)

      {:ok, session} =
        Session.start_link(
          session_id: "unowned",
          server_module: DualEraServer,
          transport: config.transport,
          task_supervisor: config.task_supervisor
        )

      request = @client_info |> tool_call_body() |> JSON.decode!()
      {:ok, response} = GenServer.call(session, {:mcp_request, request, %{}})

      identity = response |> JSON.decode!() |> tool_payload()
      assert identity["initialized_for"] == nil
    end
  end

  defp call_who_am_i(opts, call_opts \\ []) do
    conn = post_tool_call(opts, call_opts)
    assert conn.status == 200
    conn.resp_body |> JSON.decode!() |> tool_payload()
  end

  defp tool_payload(%{"result" => %{"content" => [%{"text" => text}]}}), do: JSON.decode!(text)

  defp post_tool_call(opts, call_opts) do
    call_opts |> tool_call_conn() |> StreamableHTTPPlug.call(opts)
  end

  defp tool_call_conn(call_opts) do
    client_info = Keyword.get(call_opts, :client_info, @client_info)
    extra = Keyword.get(call_opts, :headers, [])
    dropped = Keyword.get(call_opts, :drop_headers, [])

    headers =
      [{"mcp-method", "tools/call"}, {"mcp-name", "who_am_i_tool"}]
      |> Enum.reject(fn {name, _} -> name in dropped or List.keymember?(extra, name, 0) end)
      |> Kernel.++(extra)

    client_info
    |> tool_call_body()
    |> stateless_conn(headers)
    |> merge_assigns(call_opts |> Keyword.get(:assigns, %{}) |> Map.to_list())
  end

  defp tool_call_body(client_info) do
    JSON.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "who_am_i_tool", "arguments" => %{}, "_meta" => meta(client_info)}
    })
  end

  defp post_stateless(opts, method) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => %{"_meta" => meta(@client_info)}}
    |> JSON.encode!()
    |> stateless_conn([{"mcp-method", method}])
    |> StreamableHTTPPlug.call(opts)
  end

  defp post_raw(opts, body, headers) do
    body
    |> JSON.encode!()
    |> stateless_conn(headers)
    |> StreamableHTTPPlug.call(opts)
  end

  defp stateless_conn(body, headers) do
    conn =
      :post
      |> conn("/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @version)

    Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
  end

  defp meta(nil) do
    %{"io.modelcontextprotocol/protocolVersion" => @version, "io.modelcontextprotocol/clientCapabilities" => %{}}
  end

  defp meta(client_info), do: Map.put(meta(nil), "io.modelcontextprotocol/clientInfo", client_info)

  defp assert_header_mismatch(conn, header) do
    assert conn.status == 400
    error = JSON.decode!(conn.resp_body)["error"]
    assert error["code"] == -32_020
    assert inspect(error) =~ header
  end

  defp stateless_headers(conn) do
    conn
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @version)
    |> put_req_header("mcp-method", "server/discover")
  end

  defp assert_batch_refused(conn) do
    assert conn.status == 400
    assert %{"error" => %{"code" => -32_600, "data" => %{"message" => message}}} = JSON.decode!(conn.resp_body)
    assert message =~ "Batched"
  end
end
