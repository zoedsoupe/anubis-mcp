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

    test "defaults subscriber_metadata to a 1-arity function" do
      opts = StreamableHTTPPlug.init(server: StubServer)
      assert is_function(opts.subscriber_metadata, 1)
    end

    test "stores a configured subscriber_metadata callback" do
      fun = fn _conn -> %{tenant: "acme"} end
      opts = StreamableHTTPPlug.init(server: StubServer, subscriber_metadata: fun)
      assert opts.subscriber_metadata == fun
    end

    test "result is escapable so Plug.Router.forward/2 can compile it" do
      assert Macro.escape(StreamableHTTPPlug.init(server: StubServer))
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

    test "GET SSE registration attaches configured subscriber metadata", %{transport: transport} do
      opts =
        StreamableHTTPPlug.init(
          server: StubServer,
          subscriber_metadata: fn _conn -> %{tenant: "acme"} end
        )

      session_id = "meta-session-#{System.unique_integer([:positive])}"

      task =
        Task.async(fn ->
          :get
          |> conn("/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("mcp-session-id", session_id)
          |> StreamableHTTPPlug.call(opts)
        end)

      handler = wait_for_sse_handler(transport, session_id, 1_000)
      assert is_pid(handler)

      assert StreamableHTTP.handler_count(transport, &(&1[:tenant] == "acme")) == 1

      # Unblock the streaming loop so the Task can finish.
      send(handler, :close_sse)
      Task.await(task, 5_000)
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

    test "POST request does not log tool arguments", %{opts: opts, test_session_id: session_id} do
      secret = "sk-secret-#{System.unique_integer([:positive])}"
      request = build_request("tools/call", %{"name" => "echo", "arguments" => %{"token" => secret}})
      {:ok, body} = Message.encode_request(request, 1)

      log =
        capture_log([level: :debug], fn ->
          :post
          |> conn("/", body)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json")
          |> put_req_header("mcp-session-id", session_id)
          |> StreamableHTTPPlug.call(opts)
        end)

      refute log =~ secret
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

    test "POST request with unsupported MCP-Protocol-Version returns 400", %{
      opts: opts,
      test_session_id: session_id
    } do
      request = build_request("ping", %{})
      {:ok, body} = Message.encode_request(request, 1)

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "1999-01-01")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 400
      assert conn.resp_body =~ "1999-01-01"
    end

    test "POST request with a stateless-era MCP-Protocol-Version returns 400", %{
      opts: opts,
      test_session_id: session_id
    } do
      request = build_request("ping", %{})
      {:ok, body} = Message.encode_request(request, 1)
      [stateless | _] = Anubis.Protocol.Registry.stateless_versions()

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", stateless)
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["jsonrpc"] == "2.0"
      # this session-oriented endpoint's current code; the stateless binding uses -32022
      assert body["error"]["code"] == -32_603
      assert body["error"]["data"]["data"]["message"] =~ stateless
    end

    test "POST request with supported MCP-Protocol-Version succeeds", %{
      opts: opts,
      test_session_id: session_id
    } do
      request = build_request("ping", %{})
      {:ok, body} = Message.encode_request(request, 1)

      [version | _] = Anubis.Protocol.Registry.legacy_versions()

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", version)
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 200
      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["result"] == %{}
      refute Map.has_key?(decoded, "error")
    end

    test "POST request with missing method returns invalid request error", %{opts: opts} do
      payload = ~s({"jsonrpc":"2.0","id":1,"params":{}})

      conn =
        :post
        |> conn("/", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"]["code"] == -32_600
      assert body["id"] == 1
    end

    test "POST request with unknown method returns method not found error", %{opts: opts} do
      payload = ~s({"jsonrpc":"2.0","id":1,"method":"unknown/method","params":{}})

      conn =
        :post
        |> conn("/", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"]["code"] == -32_601
      assert body["id"] == 1
    end

    test "pre-parsed body with unknown method preserves request id in error", %{opts: opts} do
      conn =
        :post
        |> conn("/")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> Map.put(:body_params, %{
          "jsonrpc" => "2.0",
          "id" => 42,
          "method" => "unknown/method",
          "params" => %{}
        })
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"]["code"] == -32_601
      assert body["id"] == 42
    end

    test "pre-parsed body with missing method preserves request id in error", %{opts: opts} do
      conn =
        :post
        |> conn("/")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> Map.put(:body_params, %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "params" => %{}
        })
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"]["code"] == -32_600
      assert body["id"] == 7
    end

    test "POST request with JSON-RPC batch array returns invalid request error", %{opts: opts} do
      payload = ~s([{"jsonrpc":"2.0","id":1,"method":"tools/list"}])

      conn =
        :post
        |> conn("/", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"]["code"] == -32_600
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

      naming_registry = Registry.naming_registry_name(registry_name)
      start_supervised!({Elixir.Registry, keys: :unique, name: naming_registry})

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

    test "request to unknown session returns 404 so the client re-initializes", %{opts: opts} do
      request = build_request("tools/list", %{})
      {:ok, body} = Message.encode_request(request, 42)

      conn =
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", "expired-session-id")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 404
      assert conn.resp_body =~ "Session not found"
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

  describe "DNS rebinding protection" do
    setup do
      setup_session_config()
      on_exit(&cleanup_session_config/0)

      name = Registry.transport_name(StubServer, :streamable_http)
      sup = Registry.task_supervisor_name(StubServer)

      {:ok, _transport} =
        start_supervised({StreamableHTTP, server: StubServer, name: name, task_supervisor: sup})

      :ok
    end

    # A complete POST with Accept set: without it a 406 would hide both decisions.
    defp call(opts, host, origin) do
      request = build_request("ping", %{})
      {:ok, body} = Message.encode_request(request, 1)

      :post
      |> conn("http://#{host}:4000/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> then(fn conn ->
        if origin, do: put_req_header(conn, "origin", origin), else: conn
      end)
      |> StreamableHTTPPlug.call(opts)
    end

    defp assert_passes(opts, host, origin) do
      unchecked = StreamableHTTPPlug.init(server: StubServer)

      assert call(opts, host, origin).status == call(unchecked, host, origin).status,
             "expected host #{host} / origin #{inspect(origin)} to pass"
    end

    test "both checks are off by default" do
      opts = StreamableHTTPPlug.init(server: StubServer)

      refute call(opts, "evil.example", "http://evil.example").status in [403, 421]
    end

    test "init rejects an allowlist that is not :all, :loopback or a list of strings" do
      assert_raise ArgumentError, ~r/allowed_hosts/, fn ->
        StreamableHTTPPlug.init(server: StubServer, allowed_hosts: :localhost)
      end

      assert_raise ArgumentError, ~r/allowed_origins/, fn ->
        StreamableHTTPPlug.init(server: StubServer, allowed_origins: ["https://app.example", :all])
      end
    end

    test "allowed_hosts: :loopback rejects a foreign Host with 421" do
      opts = StreamableHTTPPlug.init(server: StubServer, allowed_hosts: :loopback)

      for host <- ["evil.example", "10.0.0.1", "0.0.0.0", "169.254.1.1"] do
        conn = call(opts, host, nil)
        assert conn.status == 421, "expected Host #{host} to be refused"
        {:ok, body} = Jason.decode(conn.resp_body)
        assert body["error"]["data"]["data"]["message"] == "Misdirected request"
      end
    end

    test "allowed_hosts: :loopback accepts the loopback hosts, port-agnostic" do
      opts = StreamableHTTPPlug.init(server: StubServer, allowed_hosts: :loopback)

      for host <- ["localhost", "127.0.0.1", "127.0.0.2", "[::1]"] do
        assert_passes(opts, host, nil)
      end
    end

    test "allowed_hosts accepts an explicit list of hostnames" do
      opts = StreamableHTTPPlug.init(server: StubServer, allowed_hosts: ["app.example"])

      assert_passes(opts, "app.example", nil)
      assert call(opts, "localhost", nil).status == 421
    end

    test "allowed_origins: :loopback rejects a foreign Origin with 403" do
      opts = StreamableHTTPPlug.init(server: StubServer, allowed_origins: :loopback)

      conn = call(opts, "localhost", "http://evil.example")

      assert conn.status == 403
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"]["data"]["data"]["message"] == "Forbidden origin"
    end

    test "allowed_origins: :loopback accepts loopback origins and no Origin at all" do
      opts = StreamableHTTPPlug.init(server: StubServer, allowed_origins: :loopback)

      origins = ["http://localhost:3000", "http://127.0.0.1:8080", "http://127.0.0.2:9000", "http://[::1]:4000", nil]

      for origin <- origins do
        assert_passes(opts, "localhost", origin)
      end
    end

    test "allowed_origins accepts an explicit list of origins" do
      opts = StreamableHTTPPlug.init(server: StubServer, allowed_origins: ["https://app.example"])

      assert_passes(opts, "app.example", "https://app.example")
      assert call(opts, "app.example", "http://localhost:3000").status == 403
    end

    test "a rebound request is refused by Host before Origin is consulted" do
      opts = StreamableHTTPPlug.init(server: StubServer, allowed_hosts: :loopback, allowed_origins: :loopback)

      assert call(opts, "evil.example", "http://evil.example").status == 421
    end

    test "the checks run before the request is otherwise processed" do
      opts = StreamableHTTPPlug.init(server: StubServer, allowed_hosts: :loopback)

      # No Accept header: the 421 instead of a 406 shows the Host gate runs first.
      conn =
        :post
        |> conn("http://evil.example:4000/", "")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 421
    end
  end
end
