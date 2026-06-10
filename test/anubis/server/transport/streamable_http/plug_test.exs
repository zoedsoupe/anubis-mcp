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
  alias Anubis.Test.MockSessionStore

  @moduletag capture_log: true

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

  defp wait_for_sse_handler(transport, session_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_sse_handler(transport, session_id, deadline)
  end

  defp do_wait_for_sse_handler(transport, session_id, deadline) do
    case StreamableHTTP.get_sse_handler(transport, session_id) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          nil
        else
          Process.sleep(10)
          do_wait_for_sse_handler(transport, session_id, deadline)
        end

      pid ->
        pid
    end
  end

  defp response_body(%Plug.Conn{resp_body: ""} = conn) do
    case conn.adapter do
      {Plug.Adapters.Test.Conn, %{chunks: chunks}} when is_binary(chunks) -> chunks
      _ -> ""
    end
  end

  defp response_body(%Plug.Conn{resp_body: body}) when is_binary(body), do: body

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
               session_header: "mcp-session-id",
               timeout: 30_000
             } = opts
    end

    test "accepts custom session header" do
      opts =
        StreamableHTTPPlug.init(
          server: StubServer,
          session_header: "x-custom-session"
        )

      assert %{
               session_header: "x-custom-session",
               timeout: 30_000
             } = opts
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

    test "parallel POST-with-SSE responses do not bleed across HTTP connections",
         %{opts: opts, transport: transport, test_session_id: session_id} do
      build_post = fn arg, request_id ->
        request =
          build_request("tools/call", %{
            "name" => "greet",
            "arguments" => %{"name" => arg}
          })

        {:ok, body} = Message.encode_request(request, request_id)

        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-session-id", session_id)
      end

      task_a =
        Task.async(fn ->
          conn_a = build_post.("ALPHA", "req-A")
          StreamableHTTPPlug.call(conn_a, opts)
        end)

      task_b =
        Task.async(fn ->
          Process.sleep(50)
          conn_b = build_post.("BRAVO", "req-B")
          StreamableHTTPPlug.call(conn_b, opts)
        end)

      conn_a = Task.await(task_a, 5_000)
      conn_b = Task.await(task_b, 5_000)

      _ = wait_for_sse_handler(transport, session_id, 0)

      body_a = response_body(conn_a)
      body_b = response_body(conn_b)

      # Spec (MCP 2025-06-18 §Streamable HTTP):
      # POST_A's SSE stream is for response_A and traffic related to
      # request_A only. It MUST NOT carry response_B.
      assert body_a =~ "Hello ALPHA!", "POST_A's connection should carry response_A"

      refute body_a =~ "Hello BRAVO!",
             "BUG: POST_B's response was delivered on POST_A's HTTP connection"

      refute body_a =~ "req-B",
             "BUG: POST_A's connection received an SSE event for request id req-B"

      assert conn_b.status == 200,
             "POST_B should return its own response on its own connection"

      assert body_b =~ "Hello BRAVO!", "POST_B's connection should carry response_B"
      assert body_b =~ "req-B"
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

    test "notification to unknown session returns 404", %{opts: opts} do
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

      assert conn.status == 404
    end

    test "request to unknown session auto-reinitializes", %{opts: opts} do
      request = build_request("tools/list", %{})
      {:ok, body} = Message.encode_request(request, 42)

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", "expired-session-id")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 200
      {:ok, response} = Jason.decode(conn.resp_body)
      assert is_map(response["result"])
      assert Map.has_key?(response["result"], "tools")
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

  describe "notification with session store configured" do
    setup do
      {:ok, _} = MockSessionStore.start_link([])
      MockSessionStore.reset!()

      original_config = Application.get_env(:anubis_mcp, :session_store)

      Application.put_env(:anubis_mcp, :session_store,
        enabled: true,
        adapter: MockSessionStore,
        ttl: 1_800_000
      )

      on_exit(fn ->
        if original_config do
          Application.put_env(:anubis_mcp, :session_store, original_config)
        else
          Application.delete_env(:anubis_mcp, :session_store)
        end
      end)

      task_sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: task_sup})

      transport_name = Registry.transport_name(StubServer, StubTransport)
      start_supervised!({StubTransport, name: transport_name})

      registry_name = Registry.registry_name(StubServer)
      start_supervised!({Registry.Local, name: registry_name})

      setup_session_config(registry_mod: Registry.Local)
      on_exit(&cleanup_session_config/0)

      session_sup_name = Registry.session_supervisor_name(StubServer)
      start_supervised!({DynamicSupervisor, name: session_sup_name, strategy: :one_for_one})

      streamable_name = Registry.transport_name(StubServer, :streamable_http)

      start_supervised!({StreamableHTTP, server: StubServer, name: streamable_name, task_supervisor: task_sup})

      opts = StreamableHTTPPlug.init(server: StubServer)

      %{opts: opts, registry_name: registry_name}
    end

    test "notification resurrects session from store when no local entry exists",
         %{opts: opts, registry_name: registry_name} do
      session_id = "stored-session-#{System.unique_integer([:positive])}"

      # Pre-populate the store as if a peer pod initialized this session.
      # The Session GenServer's auto_initialize will rehydrate from this map.
      :ok =
        MockSessionStore.save(
          session_id,
          %{
            "client_info" => %{"name" => "stored-client", "version" => "1.0"},
            "frame" => %{}
          },
          []
        )

      # Sanity check: the session is not in this pod's local registry.
      assert {:error, :not_found} = Registry.Local.lookup_session(registry_name, session_id)

      notification = build_notification("notifications/initialized", %{})
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

      # Resurrection succeeded: a Session GenServer now exists locally.
      assert {:ok, pid} = Registry.Local.lookup_session(registry_name, session_id)
      assert Process.alive?(pid)
    end

    test "notification with store + unknown session-id still returns 404",
         %{opts: opts, registry_name: registry_name} do
      session_id = "unknown-session-#{System.unique_integer([:positive])}"

      # Confirm the store has no record of this session.
      assert {:error, :not_found} = MockSessionStore.load(session_id, [])

      # Confirm the local registry has no record either.
      assert {:error, :not_found} = Registry.Local.lookup_session(registry_name, session_id)

      notification = build_notification("notifications/initialized", %{})
      {:ok, body} = Message.encode_notification(notification)

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 404

      # Spec compliance: no ghost session was minted as a side effect.
      assert {:error, :not_found} = Registry.Local.lookup_session(registry_name, session_id)
    end

    test "concurrent notifications for same session-id spawn only one Session GenServer",
         %{opts: opts, registry_name: registry_name} do
      session_id = "concurrent-session-#{System.unique_integer([:positive])}"

      :ok =
        MockSessionStore.save(
          session_id,
          %{
            "client_info" => %{"name" => "concurrent-client", "version" => "1.0"},
            "frame" => %{}
          },
          []
        )

      notification = build_notification("notifications/initialized", %{})
      {:ok, body} = Message.encode_notification(notification)

      build_conn = fn ->
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", session_id)
      end

      # Fire two plug calls concurrently. One will start_session successfully;
      # the other will match {:already_started, pid} in start_new_session/2
      # (plug.ex:395) and reuse the same PID.
      task_a = Task.async(fn -> StreamableHTTPPlug.call(build_conn.(), opts) end)
      task_b = Task.async(fn -> StreamableHTTPPlug.call(build_conn.(), opts) end)

      conn_a = Task.await(task_a)
      conn_b = Task.await(task_b)

      # Both calls succeed.
      assert conn_a.status == 202
      assert conn_b.status == 202

      # Exactly one live Session GenServer is registered for the session-id.
      assert {:ok, pid} = Registry.Local.lookup_session(registry_name, session_id)
      assert Process.alive?(pid)
    end
  end

  describe "notification with resurrection rejected by server module" do
    setup do
      {:ok, _} = MockSessionStore.start_link([])
      MockSessionStore.reset!()

      original_config = Application.get_env(:anubis_mcp, :session_store)

      Application.put_env(:anubis_mcp, :session_store,
        enabled: true,
        adapter: MockSessionStore,
        ttl: 1_800_000
      )

      on_exit(fn ->
        if original_config do
          Application.put_env(:anubis_mcp, :session_store, original_config)
        else
          Application.delete_env(:anubis_mcp, :session_store)
        end
      end)

      server = StubSessionRecoveryRejectServer
      task_sup = Registry.task_supervisor_name(server)
      start_supervised!({Task.Supervisor, name: task_sup})

      transport_name = Registry.transport_name(server, StubTransport)
      start_supervised!({StubTransport, name: transport_name})

      registry_name = Registry.registry_name(server)
      start_supervised!({Registry.Local, name: registry_name})

      session_config = %{
        server_module: server,
        registry_mod: Registry.Local,
        transport: [layer: StubTransport, name: transport_name],
        session_idle_timeout: nil,
        timeout: 30_000,
        task_supervisor: task_sup
      }

      :persistent_term.put({ServerSupervisor, server, :session_config}, session_config)
      on_exit(fn -> :persistent_term.erase({ServerSupervisor, server, :session_config}) end)

      session_sup_name = Registry.session_supervisor_name(server)
      start_supervised!({DynamicSupervisor, name: session_sup_name, strategy: :one_for_one})

      streamable_name = Registry.transport_name(server, :streamable_http)

      start_supervised!({StreamableHTTP, server: server, name: streamable_name, task_supervisor: task_sup})

      opts = StreamableHTTPPlug.init(server: server)

      %{opts: opts, registry_name: registry_name}
    end

    test "notification with rejected resurrection returns 404 and logs warning",
         %{opts: opts, registry_name: registry_name} do
      session_id = "rejected-session-#{System.unique_integer([:positive])}"

      :ok =
        MockSessionStore.save(
          session_id,
          %{
            "client_info" => %{"name" => "rejected-client", "version" => "1.0"},
            "frame" => %{}
          },
          []
        )

      notification = build_notification("notifications/initialized", %{})
      {:ok, body} = Message.encode_notification(notification)

      log =
        capture_log(fn ->
          conn =
            :post
            |> conn("/", body)
            |> put_req_header("content-type", "application/json")
            |> put_req_header("accept", "application/json")
            |> put_req_header("mcp-session-id", session_id)
            |> StreamableHTTPPlug.call(opts)

          assert conn.status == 404
        end)

      # The warning event fires when start_and_auto_initialize_session/2
      # returns {:error, {:recovery_rejected, _}} and our resurrect_via_store
      # helper logs + normalizes to :not_found.
      assert log =~ "session_resurrect_failed"
      assert log =~ "recovery_rejected"

      # start_and_auto_initialize_session/2 cleans up the failed session, so
      # the registry should be empty.
      assert {:error, :not_found} = Registry.Local.lookup_session(registry_name, session_id)
    end
  end

  describe "response with session store configured" do
    setup do
      {:ok, _} = MockSessionStore.start_link([])
      MockSessionStore.reset!()

      original_config = Application.get_env(:anubis_mcp, :session_store)

      Application.put_env(:anubis_mcp, :session_store,
        enabled: true,
        adapter: MockSessionStore,
        ttl: 1_800_000
      )

      on_exit(fn ->
        if original_config do
          Application.put_env(:anubis_mcp, :session_store, original_config)
        else
          Application.delete_env(:anubis_mcp, :session_store)
        end
      end)

      task_sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: task_sup})

      transport_name = Registry.transport_name(StubServer, StubTransport)
      start_supervised!({StubTransport, name: transport_name})

      registry_name = Registry.registry_name(StubServer)
      start_supervised!({Registry.Local, name: registry_name})

      setup_session_config(registry_mod: Registry.Local)
      on_exit(&cleanup_session_config/0)

      session_sup_name = Registry.session_supervisor_name(StubServer)
      start_supervised!({DynamicSupervisor, name: session_sup_name, strategy: :one_for_one})

      streamable_name = Registry.transport_name(StubServer, :streamable_http)

      start_supervised!({StreamableHTTP, server: StubServer, name: streamable_name, task_supervisor: task_sup})

      opts = StreamableHTTPPlug.init(server: StubServer)

      %{opts: opts, registry_name: registry_name}
    end

    test "response resurrects session from store when no local entry exists",
         %{opts: opts, registry_name: registry_name} do
      session_id = "response-stored-#{System.unique_integer([:positive])}"

      :ok =
        MockSessionStore.save(
          session_id,
          %{
            "client_info" => %{"name" => "response-client", "version" => "1.0"},
            "frame" => %{}
          },
          []
        )

      assert {:error, :not_found} = Registry.Local.lookup_session(registry_name, session_id)

      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "req_42",
          "result" => %{"some" => "data"}
        })

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 202
      assert conn.resp_body == "{}"

      assert {:ok, pid} = Registry.Local.lookup_session(registry_name, session_id)
      assert Process.alive?(pid)
    end

    test "response with store + unknown session-id still returns 404",
         %{opts: opts, registry_name: registry_name} do
      session_id = "response-unknown-#{System.unique_integer([:positive])}"

      assert {:error, :not_found} = MockSessionStore.load(session_id, [])
      assert {:error, :not_found} = Registry.Local.lookup_session(registry_name, session_id)

      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "req_99",
          "result" => %{"some" => "data"}
        })

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 404
      assert {:error, :not_found} = Registry.Local.lookup_session(registry_name, session_id)
    end
  end
end
