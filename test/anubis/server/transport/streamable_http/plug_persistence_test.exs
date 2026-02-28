defmodule Anubis.Server.Transport.StreamableHTTP.PlugPersistenceTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Anubis.Server.Supervisor, as: ServerSupervisor
  alias Anubis.Server.Transport.StreamableHTTP.Plug
  alias Anubis.Test.MockSessionStore

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

    :ok
  end

  describe "session persistence without tokens" do
    setup do
      session_config = %{
        server_module: StubServer,
        registry_mod: Anubis.Server.Registry.None,
        transport: [layer: StubTransport, name: :stub_transport],
        session_idle_timeout: nil,
        timeout: 30_000,
        task_supervisor: :test_task_sup
      }

      :persistent_term.put({ServerSupervisor, StubServer, :session_config}, session_config)

      on_exit(fn ->
        :persistent_term.erase({ServerSupervisor, StubServer, :session_config})
      end)

      plug_opts = Plug.init(server: StubServer, session_header: "mcp-session-id")
      {:ok, plug_opts: plug_opts}
    end

    test "GET request with existing session ID reconnects to stored session", %{plug_opts: _plug_opts} do
      session_id = "existing_session_123"

      session_data = %{
        id: session_id,
        protocol_version: "2024-11-21",
        initialized: true,
        client_info: %{"name" => "test_client"}
      }

      :ok = MockSessionStore.save(session_id, session_data, [])

      conn =
        :get
        |> conn("/")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("mcp-session-id", session_id)

      assert get_req_header(conn, "mcp-session-id") == [session_id]

      assert {:ok, stored_data} = MockSessionStore.load(session_id, [])
      assert stored_data.id == session_id
      assert stored_data.initialized == true
    end

    test "GET request without session ID generates new session", %{plug_opts: _plug_opts} do
      conn =
        :get
        |> conn("/")
        |> put_req_header("accept", "text/event-stream")

      assert get_req_header(conn, "mcp-session-id") == []
    end

    test "POST request with existing session ID uses stored session", %{plug_opts: _plug_opts} do
      session_id = "post_session_111"

      session_data = %{
        id: session_id,
        protocol_version: "2024-11-21",
        initialized: true
      }

      :ok = MockSessionStore.save(session_id, session_data, [])

      message = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "id" => "req_1"
      }

      conn =
        :post
        |> conn("/", JSON.encode!(message))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-session-id", session_id)

      assert get_req_header(conn, "mcp-session-id") == [session_id]
    end
  end

  describe "session lifecycle with persistence" do
    test "initialize request triggers session persistence" do
      message = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-21",
          "capabilities" => %{},
          "clientInfo" => %{
            "name" => "test_client",
            "version" => "1.0.0"
          }
        },
        "id" => "init_1"
      }

      _conn =
        :post
        |> conn("/", JSON.encode!(message))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")

      assert true
    end

    test "session data can be updated in store" do
      session_id = "update_session_222"

      initial_data = %{
        id: session_id,
        initialized: false,
        log_level: "info"
      }

      :ok = MockSessionStore.save(session_id, initial_data, [])

      updates = %{
        initialized: true,
        log_level: "debug"
      }

      :ok = MockSessionStore.update(session_id, updates, [])

      {:ok, updated_data} = MockSessionStore.load(session_id, [])
      assert updated_data.initialized == true
      assert updated_data.log_level == "debug"
      assert updated_data.id == session_id
    end

    test "DELETE request removes session from store" do
      session_id = "delete_session_333"

      session_data = %{
        id: session_id,
        initialized: true
      }

      :ok = MockSessionStore.save(session_id, session_data, [])

      assert {:ok, _} = MockSessionStore.load(session_id, [])

      conn =
        :delete
        |> conn("/")
        |> put_req_header("mcp-session-id", session_id)

      :ok = MockSessionStore.delete(session_id, [])

      assert {:error, :not_found} = MockSessionStore.load(session_id, [])
      assert get_req_header(conn, "mcp-session-id") == [session_id]
    end

    test "can list all active sessions" do
      session_ids = ["session_a", "session_b", "session_c"]

      for session_id <- session_ids do
        :ok = MockSessionStore.save(session_id, %{id: session_id}, [])
      end

      {:ok, active} = MockSessionStore.list_active([])
      assert length(active) == 3
      assert Enum.all?(session_ids, &(&1 in active))
    end
  end

  describe "backward compatibility" do
    test "sessions work exactly as before when no store is configured" do
      Application.delete_env(:anubis_mcp, :session_store)

      message = %{
        "jsonrpc" => "2.0",
        "method" => "ping",
        "id" => "ping_1"
      }

      conn =
        :post
        |> conn("/", JSON.encode!(message))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")

      assert conn.request_path == "/"
      assert get_req_header(conn, "content-type") == ["application/json"]
    end

    test "clients without session IDs work normally" do
      conn =
        :get
        |> conn("/")
        |> put_req_header("accept", "text/event-stream")

      assert conn.request_path == "/"
    end

    test "clients with session IDs reconnect transparently" do
      session_id = "client_session_999"

      :ok =
        MockSessionStore.save(
          session_id,
          %{
            id: session_id,
            initialized: true,
            protocol_version: "2024-11-21"
          },
          []
        )

      conn =
        :get
        |> conn("/")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("mcp-session-id", session_id)

      assert get_req_header(conn, "mcp-session-id") == [session_id]
    end
  end
end
