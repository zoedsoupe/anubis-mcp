defmodule Anubis.Server.Transport.StreamableHTTP.SessionRecoveryTest do
  @moduledoc """
  Regression tests for "session drops" reported in dev mode (e.g. after a
  recompile). The underlying issue is broader than recompilation: any time the
  Session GenServer dies and is restarted by the DynamicSupervisor — or any
  time the supervisor's `:one_for_all` strategy takes the whole subtree down —
  subsequent client requests with the same `mcp-session-id` are rejected.

  Two failure modes are exercised here:

    1. With no session store configured: after a Session crash the
       DynamicSupervisor restarts the child, but the new pid is never
       re-registered in the ETS registry, so the Plug returns "No active
       session" forever.

    2. With a session store configured: the Session faithfully persists state
       on init, but nothing in `Plug.find_or_create_session/3` consults the
       store when the session is missing from the registry — `store.load/2` has
       no callers in lib code today. Even fully-persisted sessions are
       irrecoverable.
  """
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

  @session_id "session-recovery-test"

  defp setup_session_config(opts) do
    task_sup = Registry.task_supervisor_name(StubServer)
    transport_name = Registry.transport_name(StubServer, StubTransport)

    session_config = %{
      server_module: StubServer,
      registry_mod: Keyword.get(opts, :registry_mod, Registry.Local),
      transport: [layer: StubTransport, name: transport_name],
      session_idle_timeout: nil,
      timeout: 30_000,
      task_supervisor: task_sup
    }

    :persistent_term.put({ServerSupervisor, StubServer, :session_config}, session_config)
    session_config
  end

  defp boot_streamable_http_stack do
    task_sup = Registry.task_supervisor_name(StubServer)
    start_supervised!({Task.Supervisor, name: task_sup})

    transport_name = Registry.transport_name(StubServer, StubTransport)
    start_supervised!({StubTransport, name: transport_name})

    registry_name = Registry.registry_name(StubServer)
    start_supervised!({Registry.Local, name: registry_name})

    session_config = setup_session_config(registry_mod: Registry.Local)

    on_exit(fn ->
      :persistent_term.erase({ServerSupervisor, StubServer, :session_config})
    end)

    session_sup_name = Registry.session_supervisor_name(StubServer)
    start_supervised!({DynamicSupervisor, name: session_sup_name, strategy: :one_for_one})

    http_name = Registry.transport_name(StubServer, :streamable_http)

    {:ok, _transport} =
      start_supervised({StreamableHTTP, server: StubServer, name: http_name, task_supervisor: task_sup})

    opts = StreamableHTTPPlug.init(server: StubServer)

    %{
      opts: opts,
      task_sup: task_sup,
      registry_name: registry_name,
      session_sup_name: session_sup_name,
      session_config: session_config
    }
  end

  defp initialize_via_plug(opts, session_id) do
    init_request =
      build_request("initialize", %{
        "protocolVersion" => "2025-03-26",
        "clientInfo" => %{"name" => "test", "version" => "1.0.0"},
        "capabilities" => %{}
      })

    {:ok, body} = Message.encode_request(init_request, "init_1")

    conn =
      :post
      |> conn("/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> put_req_header("mcp-session-id", session_id)
      |> StreamableHTTPPlug.call(opts)

    assert conn.status == 200, "initialize handshake should succeed, got #{conn.status} #{conn.resp_body}"

    initialized = build_notification("notifications/initialized", %{})

    {:ok, init_body} = Message.encode_notification(initialized)

    :post
    |> conn("/", init_body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> StreamableHTTPPlug.call(opts)

    Process.sleep(20)
    :ok
  end

  defp ping(opts, session_id) do
    request = build_request("ping", %{})
    {:ok, body} = Message.encode_request(request, "ping_1")

    :post
    |> conn("/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> StreamableHTTPPlug.call(opts)
  end

  describe "session recovery without session store" do
    setup do
      ctx = boot_streamable_http_stack()
      capture_log(fn -> initialize_via_plug(ctx.opts, @session_id) end)
      ctx
    end

    test "follow-up request survives a Session crash", ctx do
      {:ok, session_pid} = Registry.Local.lookup_session(ctx.registry_name, @session_id)
      assert Process.alive?(session_pid)

      ref = Process.monitor(session_pid)

      Process.exit(session_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session_pid, _}, 500
      # let the DynamicSupervisor restart and the registry process the DOWN
      Process.sleep(50)

      conn = ping(ctx.opts, @session_id)

      assert conn.status == 200,
             "expected the transport to recover the session after a crash, " <>
               "got status #{conn.status} with body #{conn.resp_body}"
    end
  end

  describe "session recovery with persistence store" do
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

      ctx = boot_streamable_http_stack()
      capture_log(fn -> initialize_via_plug(ctx.opts, @session_id) end)
      ctx
    end

    test "persisted session is rehydrated after the Session pid dies", ctx do
      assert {:ok, stored} = MockSessionStore.load(@session_id, [])
      assert stored.initialized == true, "initialize/initialized should have persisted state"

      {:ok, session_pid} = Registry.Local.lookup_session(ctx.registry_name, @session_id)
      ref = Process.monitor(session_pid)

      Process.exit(session_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session_pid, _}, 500
      Process.sleep(50)

      conn = ping(ctx.opts, @session_id)

      assert conn.status == 200,
             "expected the transport to rehydrate the persisted session, " <>
               "got status #{conn.status} with body #{conn.resp_body}"
    end
  end
end
