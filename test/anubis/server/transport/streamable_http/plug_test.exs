defmodule Anubis.Server.Transport.StreamableHTTP.PlugTest do
  use Anubis.MCP.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Anubis.MCP.Message
  alias Anubis.Server.Session
  alias Anubis.Server.Supervisor, as: ServerSupervisor
  alias Anubis.Server.Transport.StreamableHTTP
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  setup :with_default_registry

  describe "init/1" do
    test "requires server option" do
      assert_raise KeyError, fn ->
        StreamableHTTPPlug.init([])
      end
    end

    test "initializes with valid options", %{registry: registry} do
      opts = StreamableHTTPPlug.init(server: StubServer)

      assert %{
               transport: transport,
               session_header: "mcp-session-id",
               timeout: 30_000
             } = opts

      assert transport == registry.transport(StubServer, :streamable_http)
    end

    test "accepts custom session header", %{registry: registry} do
      opts =
        StreamableHTTPPlug.init(
          server: StubServer,
          session_header: "x-custom-session"
        )

      assert %{
               transport: transport,
               session_header: "x-custom-session",
               timeout: 30_000
             } = opts

      assert transport == registry.transport(StubServer, :streamable_http)
    end

    test "uses custom registry when provided" do
      start_supervised!(MockCustomRegistry)
      assert Process.whereis(MockCustomRegistry)

      opts =
        StreamableHTTPPlug.init(
          server: StubServer,
          mode: :streamable_http,
          registry: MockCustomRegistry
        )

      expected_transport = MockCustomRegistry.transport(StubServer, :streamable_http)

      assert opts.transport == expected_transport
    end
  end

  describe "GET endpoint" do
    setup %{registry: registry} do
      name = registry.transport(StubServer, :streamable_http)
      sup = registry.task_supervisor(StubServer)

      {:ok, transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, registry: registry, task_supervisor: sup})

      opts = StreamableHTTPPlug.init(server: StubServer)

      %{opts: opts, transport: transport}
    end

    test "GET request establishes SSE connection", %{transport: transport} do
      conn =
        :get
        |> conn("/")
        |> put_req_header("accept", "text/event-stream")

      assert conn.method == "GET"
      assert get_req_header(conn, "accept") == ["text/event-stream"]

      session_id = "test-session-123"
      assert :ok = StreamableHTTP.register_sse_handler(transport, session_id)

      capture_log(fn ->
        StreamableHTTP.unregister_sse_handler(transport, session_id)
        Process.sleep(10)
      end)
    end

    test "GET request without SSE accept header returns error", %{opts: opts} do
      conn =
        :get
        |> conn("/")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 406
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"]["message"] == "Invalid Request"
    end
  end

  describe "POST endpoint" do
    setup %{registry: registry} do
      name = registry.transport(StubServer, :streamable_http)
      sup = registry.task_supervisor(StubServer)
      start_supervised!({Task.Supervisor, name: sup})

      # Store session config in persistent_term for Plug access
      session_config = %{
        server_module: StubServer,
        registry: registry,
        transport: [layer: StubTransport, name: registry.transport(StubServer, StubTransport)],
        session_idle_timeout: nil,
        timeout: 30_000,
        task_supervisor: sup
      }

      :persistent_term.put({ServerSupervisor, StubServer, :session_config}, session_config)

      # Start a DynamicSupervisor for sessions
      session_sup_name = registry.supervisor(:session_supervisor, StubServer)
      start_supervised!({DynamicSupervisor, name: session_sup_name, strategy: :one_for_one})

      # Start stub transport for Session to use
      transport_name = registry.transport(StubServer, StubTransport)
      start_supervised!({StubTransport, name: transport_name})

      {:ok, transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, registry: registry, task_supervisor: sup})

      opts = StreamableHTTPPlug.init(server: StubServer)

      # Pre-create an initialized session for notification/request tests
      test_session_id = "post-test-session"
      session_name = registry.server_session(StubServer, test_session_id)

      {:ok, _session} =
        ServerSupervisor.start_session(registry, StubServer,
          session_id: test_session_id,
          server_module: StubServer,
          name: session_name,
          transport: [layer: StubTransport, name: transport_name],
          registry: registry,
          session_idle_timeout: 1_800_000,
          timeout: 30_000,
          task_supervisor: sup
        )

      # Initialize the session
      init_req = %{
        "jsonrpc" => "2.0",
        "id" => "setup_init",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "clientInfo" => %{"name" => "Test", "version" => "1.0"},
          "capabilities" => %{}
        }
      }

      {:ok, _} = GenServer.call(session_name, {:mcp_request, init_req, %{}})

      GenServer.cast(
        session_name,
        {:mcp_notification, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, %{}}
      )

      Process.sleep(30)

      on_exit(fn ->
        :persistent_term.erase({ServerSupervisor, StubServer, :session_config})
      end)

      %{opts: opts, transport: transport, test_session_id: test_session_id}
    end

    test "POST request with notification returns 202", %{opts: opts, test_session_id: session_id} do
      notification =
        build_notification("notifications/message", %{
          "level" => "info",
          "data" => "test"
        })

      {:ok, body} = Message.encode_notification(notification)

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 202
      assert conn.resp_body == "{}"
    end

    test "POST request with valid request returns response", %{opts: opts, test_session_id: session_id} do
      request = build_request("ping", %{})
      {:ok, body} = Message.encode_request(request, 1)

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 200
      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["result"] == %{}
    end

    test "POST request with invalid JSON returns error", %{opts: opts} do
      conn =
        :post
        |> conn("/", "invalid json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"]["code"] == -32_700
    end
  end

  describe "DELETE endpoint" do
    setup %{registry: registry} do
      name = registry.transport(StubServer, :streamable_http)
      sup = registry.task_supervisor(StubServer)

      {:ok, transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, registry: registry, task_supervisor: sup})

      opts = StreamableHTTPPlug.init(server: StubServer)

      %{opts: opts, transport: transport}
    end

    test "DELETE request with session ID returns success", %{opts: opts} do
      conn =
        :delete
        |> conn("/")
        |> put_req_header("mcp-session-id", "test-session")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 200
      assert conn.resp_body == "{}"
    end

    test "DELETE request without session ID returns error", %{opts: opts} do
      conn =
        :delete
        |> conn("/")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"]["message"] == "Internal error"
    end
  end

  describe "unsupported methods" do
    setup %{registry: registry} do
      name = registry.transport(StubServer, :streamable_http)
      sup = registry.task_supervisor(StubServer)

      {:ok, _transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, registry: registry, task_supervisor: sup})

      opts = StreamableHTTPPlug.init(server: StubServer)

      %{opts: opts}
    end

    test "non-supported method returns 405", %{opts: opts} do
      conn =
        :put
        |> conn("/", "")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 405
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"]["message"] == "Method not found"
    end
  end

  describe "session handling" do
    setup %{registry: registry} do
      name = registry.transport(StubServer, :streamable_http)
      sup = registry.task_supervisor(StubServer)
      start_supervised!({Task.Supervisor, name: sup})

      transport_name = registry.transport(StubServer, StubTransport)

      session_config = %{
        server_module: StubServer,
        registry: registry,
        transport: [layer: StubTransport, name: transport_name],
        session_idle_timeout: nil,
        timeout: 30_000,
        task_supervisor: sup
      }

      :persistent_term.put({ServerSupervisor, StubServer, :session_config}, session_config)

      session_sup_name = registry.supervisor(:session_supervisor, StubServer)
      start_supervised!({DynamicSupervisor, name: session_sup_name, strategy: :one_for_one})

      start_supervised!({StubTransport, name: transport_name})

      {:ok, transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, registry: registry, task_supervisor: sup})

      opts = StreamableHTTPPlug.init(server: StubServer)

      # Pre-create an initialized session
      test_session_id = "session-handling-test"
      session_name = registry.server_session(StubServer, test_session_id)

      {:ok, _session} =
        ServerSupervisor.start_session(registry, StubServer,
          session_id: test_session_id,
          server_module: StubServer,
          name: session_name,
          transport: [layer: StubTransport, name: transport_name],
          registry: registry,
          session_idle_timeout: 1_800_000,
          timeout: 30_000,
          task_supervisor: sup
        )

      init_req = %{
        "jsonrpc" => "2.0",
        "id" => "setup_init",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "clientInfo" => %{"name" => "Test", "version" => "1.0"},
          "capabilities" => %{}
        }
      }

      {:ok, _} = GenServer.call(session_name, {:mcp_request, init_req, %{}})

      GenServer.cast(
        session_name,
        {:mcp_notification, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, %{}}
      )

      Process.sleep(30)

      on_exit(fn ->
        :persistent_term.erase({ServerSupervisor, StubServer, :session_config})
      end)

      %{opts: opts, transport: transport, test_session_id: test_session_id}
    end

    test "extracts session ID from header", %{opts: opts, test_session_id: session_id} do
      notification =
        build_notification("notifications/message", %{
          "level" => "info",
          "data" => "test"
        })

      {:ok, body} = Message.encode_notification(notification)

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 202
    end

    test "notification to unknown session returns 400", %{opts: opts} do
      notification =
        build_notification("notifications/message", %{
          "level" => "info",
          "data" => "test"
        })

      {:ok, body} = Message.encode_notification(notification)

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", "unknown-session")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 400
    end

    test "initialize request creates new session", %{opts: opts} do
      init_request =
        build_request("initialize", %{
          "protocolVersion" => "2025-03-26",
          "clientInfo" => %{"name" => "test", "version" => "1.0.0"},
          "capabilities" => %{}
        })

      {:ok, body} = Message.encode_request(init_request, 1)

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 200
      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["result"]["protocolVersion"]
    end
  end
end
