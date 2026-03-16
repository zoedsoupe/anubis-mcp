defmodule Anubis.Server.Transport.StreamableHTTP.PlugTest do
  use Anubis.MCP.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Anubis.MCP.Message
  alias Anubis.Server.Registry
  alias Anubis.Server.Supervisor, as: ServerSupervisor
  alias Anubis.Server.Transport.StreamableHTTP
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  defp setup_session_config(opts \\ []) do
    task_sup = Registry.task_supervisor_name(StubServer)
    transport_name = Registry.transport_name(StubServer, StubTransport)

    session_config = %{
      server_module: StubServer,
      registry_mod: Keyword.get(opts, :registry_mod, Registry.None),
      transport: [layer: StubTransport, name: transport_name],
      session_idle_timeout: nil,
      timeout: 30_000,
      task_supervisor: task_sup
    }

    :persistent_term.put({ServerSupervisor, StubServer, :session_config}, session_config)
    session_config
  end

  defp cleanup_session_config do
    :persistent_term.erase({ServerSupervisor, StubServer, :session_config})
  end

  describe "init/1" do
    setup do
      setup_session_config()
      on_exit(&cleanup_session_config/0)
      :ok
    end

    test "requires server option" do
      assert_raise KeyError, fn ->
        StreamableHTTPPlug.init([])
      end
    end

    test "initializes with valid options" do
      opts = StreamableHTTPPlug.init(server: StubServer)

      assert %{
               transport: transport,
               session_header: "mcp-session-id",
               timeout: 30_000
             } = opts

      assert transport == Registry.transport_name(StubServer, :streamable_http)
    end

    test "accepts custom session header" do
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

      assert transport == Registry.transport_name(StubServer, :streamable_http)
    end
  end

  describe "GET endpoint" do
    setup do
      setup_session_config()
      on_exit(&cleanup_session_config/0)

      name = Registry.transport_name(StubServer, :streamable_http)
      sup = Registry.task_supervisor_name(StubServer)

      {:ok, transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, task_supervisor: sup})

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
    setup do
      task_sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: task_sup})

      transport_name = Registry.transport_name(StubServer, StubTransport)
      start_supervised!({StubTransport, name: transport_name})

      registry_name = Registry.registry_name(StubServer)
      start_supervised!({Registry.Local, name: registry_name})

      session_config = setup_session_config(registry_mod: Registry.Local)
      on_exit(&cleanup_session_config/0)

      session_sup_name = Registry.session_supervisor_name(StubServer)
      start_supervised!({DynamicSupervisor, name: session_sup_name, strategy: :one_for_one})

      name = Registry.transport_name(StubServer, :streamable_http)

      {:ok, transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, task_supervisor: task_sup})

      opts = StreamableHTTPPlug.init(server: StubServer)

      test_session_id = "post-test-session"
      session_name = Registry.session_name(StubServer, test_session_id)

      {:ok, _session} =
        ServerSupervisor.start_session(StubServer,
          session_id: test_session_id,
          server_module: StubServer,
          name: session_name,
          transport: session_config.transport,
          session_idle_timeout: 1_800_000,
          timeout: 30_000,
          task_supervisor: task_sup
        )

      Registry.Local.register_session(registry_name, test_session_id, Process.whereis(session_name))

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
    setup do
      setup_session_config()
      on_exit(&cleanup_session_config/0)

      name = Registry.transport_name(StubServer, :streamable_http)
      sup = Registry.task_supervisor_name(StubServer)

      {:ok, transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, task_supervisor: sup})

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
    setup do
      setup_session_config()
      on_exit(&cleanup_session_config/0)

      name = Registry.transport_name(StubServer, :streamable_http)
      sup = Registry.task_supervisor_name(StubServer)

      {:ok, _transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, task_supervisor: sup})

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
    setup do
      task_sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: task_sup})

      transport_name = Registry.transport_name(StubServer, StubTransport)
      start_supervised!({StubTransport, name: transport_name})

      registry_name = Registry.registry_name(StubServer)
      start_supervised!({Registry.Local, name: registry_name})

      session_config = setup_session_config(registry_mod: Registry.Local)
      on_exit(&cleanup_session_config/0)

      session_sup_name = Registry.session_supervisor_name(StubServer)
      start_supervised!({DynamicSupervisor, name: session_sup_name, strategy: :one_for_one})

      name = Registry.transport_name(StubServer, :streamable_http)

      {:ok, transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, task_supervisor: task_sup})

      opts = StreamableHTTPPlug.init(server: StubServer)

      test_session_id = "session-handling-test"
      session_name = Registry.session_name(StubServer, test_session_id)

      {:ok, _session} =
        ServerSupervisor.start_session(StubServer,
          session_id: test_session_id,
          server_module: StubServer,
          name: session_name,
          transport: session_config.transport,
          session_idle_timeout: 1_800_000,
          timeout: 30_000,
          task_supervisor: task_sup
        )

      Registry.Local.register_session(registry_name, test_session_id, Process.whereis(session_name))

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
