defmodule Anubis.Server.Session.StoreTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Registry
  alias Anubis.Server.Session
  alias Anubis.Test.MockSessionStore

  @moduletag capture_log: true

  setup do
    start_supervised!(MockSessionStore)
    MockSessionStore.reset!()

    original_config = Application.get_env(:anubis_mcp, :session_store)

    Application.put_env(:anubis_mcp, :session_store,
      enabled: true,
      adapter: MockSessionStore,
      ttl: 1800
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

  describe "session persistence" do
    setup do
      task_sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: task_sup})

      transport_name = Registry.transport_name(StubServer, StubTransport)
      start_supervised!({StubTransport, name: transport_name})

      %{transport_name: transport_name, task_sup: task_sup}
    end

    test "saves session state when initialized", %{
      transport_name: transport_name,
      task_sup: task_sup
    } do
      session_id = "test_session_123"
      session_name = Registry.session_name(StubServer, session_id)

      start_supervised!(
        {Session,
         session_id: session_id,
         server_module: StubServer,
         name: session_name,
         transport: [layer: StubTransport, name: transport_name],
         task_supervisor: task_sup},
        id: :persist_session
      )

      init_request = %{
        "jsonrpc" => "2.0",
        "id" => "init_1",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "clientInfo" => %{"name" => "test_client", "version" => "1.0.0"},
          "capabilities" => %{"tools" => %{}}
        }
      }

      {:ok, _} = GenServer.call(session_name, {:mcp_request, init_request, %{}})

      init_notif = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }

      GenServer.cast(session_name, {:mcp_notification, init_notif, %{}})
      Process.sleep(50)

      {:ok, stored_state} = MockSessionStore.load(session_id, [])
      assert stored_state.initialized == true
      assert stored_state.client_info["name"] == "test_client"
    end

    test "persisted session state is JSON-encodable", %{
      transport_name: transport_name,
      task_sup: task_sup
    } do
      session_id = "json_encode_session"
      session_name = Registry.session_name(StubServer, session_id)

      start_supervised!(
        {Session,
         session_id: session_id,
         server_module: StubServer,
         name: session_name,
         transport: [layer: StubTransport, name: transport_name],
         task_supervisor: task_sup},
        id: :json_encode_session
      )

      init_request = %{
        "jsonrpc" => "2.0",
        "id" => "init_json",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "clientInfo" => %{"name" => "json_client", "version" => "1.0.0"},
          "capabilities" => %{"tools" => %{}}
        }
      }

      {:ok, _} = GenServer.call(session_name, {:mcp_request, init_request, %{}})

      init_notif = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }

      GenServer.cast(session_name, {:mcp_notification, init_notif, %{}})
      Process.sleep(50)

      {:ok, stored_state} = MockSessionStore.load(session_id, [])

      json = JSON.encode!(stored_state)
      assert is_binary(json)
    end

    test "handles session updates atomically" do
      session_id = "update_session_111"

      initial_data = %{
        id: session_id,
        log_level: "info",
        initialized: false
      }

      :ok = MockSessionStore.save(session_id, initial_data, [])

      updates = %{
        log_level: "debug",
        initialized: true
      }

      :ok = MockSessionStore.update(session_id, updates, [])

      {:ok, stored_session} = MockSessionStore.load(session_id, [])
      assert stored_session[:log_level] == "debug"
      assert stored_session[:initialized] == true
      assert stored_session[:id] == session_id
    end

    test "lists active sessions" do
      session_ids = ["session_a", "session_b", "session_c"]

      for session_id <- session_ids do
        MockSessionStore.save(session_id, %{id: session_id}, [])
      end

      {:ok, active} = MockSessionStore.list_active([])
      assert length(active) == 3
      assert Enum.all?(session_ids, &(&1 in active))
    end

    test "deletes sessions from store" do
      session_id = "delete_session_222"

      :ok = MockSessionStore.save(session_id, %{id: session_id}, [])

      assert {:ok, _} = MockSessionStore.load(session_id, [])

      :ok = MockSessionStore.delete(session_id, [])

      assert {:error, :not_found} = MockSessionStore.load(session_id, [])
    end
  end

  describe "session store configuration" do
    test "works without store configured" do
      Application.delete_env(:anubis_mcp, :session_store)

      task_sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: task_sup})
      transport_name = Registry.transport_name(StubServer, StubTransport)
      start_supervised!({StubTransport, name: transport_name})

      session_id = "no_store_session"
      session_name = Registry.session_name(StubServer, session_id)

      session =
        start_supervised!(
          {Session,
           session_id: session_id,
           server_module: StubServer,
           name: session_name,
           transport: [layer: StubTransport, name: transport_name],
           task_supervisor: task_sup},
          id: :no_store_session
        )

      init_request = %{
        "jsonrpc" => "2.0",
        "id" => "init_1",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "clientInfo" => %{"name" => "test", "version" => "1.0.0"},
          "capabilities" => %{}
        }
      }

      {:ok, _} = GenServer.call(session_name, {:mcp_request, init_request, %{}})

      init_notif = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }

      GenServer.cast(session_name, {:mcp_notification, init_notif, %{}})
      Process.sleep(30)

      state = :sys.get_state(session)
      assert state.initialized == true
    end
  end
end
