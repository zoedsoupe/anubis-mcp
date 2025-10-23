defmodule Anubis.Server.Session.StoreTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Session
  alias Anubis.Server.Session.Supervisor, as: SessionSupervisor
  alias Anubis.Test.MockSessionStore

  setup do
    # Start the mock store
    {:ok, _} = MockSessionStore.start_link([])
    MockSessionStore.reset!()

    # Configure the application to use the mock store
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
    test "saves session state when initialized" do
      session_id = "test_session_123"
      {:ok, _} = Registry.start_link(keys: :unique, name: TestSessionRegistry)
      session_name = {:via, Registry, {TestSessionRegistry, session_id}}

      # Start a session
      {:ok, _pid} =
        Session.start_link(
          session_id: session_id,
          name: session_name,
          server_module: TestServer
        )

      # Initialize the session
      Session.update_from_initialization(
        session_name,
        "2024-11-21",
        %{"name" => "test_client", "version" => "1.0.0"},
        %{"tools" => %{}}
      )

      Session.mark_initialized(session_name)

      # Check that session was persisted
      {:ok, stored_state} = MockSessionStore.load(session_id, [])
      assert stored_state.protocol_version == "2024-11-21"
      assert stored_state.initialized == true
      assert stored_state.client_info["name"] == "test_client"
    end

    test "restores session from store on startup" do
      session_id = "existing_session_456"
      {:ok, _} = Registry.start_link(keys: :unique, name: TestSessionRegistry2)

      # Pre-populate store with session data
      session_data = %{
        id: session_id,
        protocol_version: "2024-11-21",
        initialized: true,
        client_info: %{"name" => "restored_client"},
        client_capabilities: %{"tools" => %{}},
        log_level: "info",
        pending_requests: %{}
      }

      :ok = MockSessionStore.save(session_id, session_data, [])

      # Start a new session with the same ID
      session_name = {:via, Registry, {TestSessionRegistry2, session_id}}

      {:ok, _pid} =
        Session.start_link(
          session_id: session_id,
          name: session_name,
          server_module: TestServer
        )

      # Verify the session was restored with the persisted data
      session = Session.get(session_name)
      assert session.protocol_version == "2024-11-21"
      assert session.initialized == true
      assert session.client_info["name"] == "restored_client"
    end

    test "persists sessions without tokens" do
      session_id = "simple_session_789"
      {:ok, _} = Registry.start_link(keys: :unique, name: TestSessionRegistry3)
      session_name = {:via, Registry, {TestSessionRegistry3, session_id}}

      {:ok, _pid} =
        Session.start_link(
          session_id: session_id,
          name: session_name,
          server_module: TestServer
        )

      # Mark as initialized to trigger persistence
      Session.mark_initialized(session_name)

      # Verify session was persisted
      {:ok, stored_state} = MockSessionStore.load(session_id, [])
      assert stored_state.initialized == true
      assert stored_state.id == session_id
    end

    test "handles session updates atomically" do
      session_id = "update_session_111"
      {:ok, _} = Registry.start_link(keys: :unique, name: TestSessionRegistry4)
      session_name = {:via, Registry, {TestSessionRegistry4, session_id}}

      {:ok, _pid} =
        Session.start_link(
          session_id: session_id,
          name: session_name,
          server_module: TestServer
        )

      # Initialize and persist
      Session.mark_initialized(session_name)

      # Update log level
      Session.set_log_level(session_name, "debug")

      # Track a request
      Session.track_request(session_name, "req_1", "tools/list")

      # Verify updates were persisted
      session = Session.get(session_name)
      assert session.log_level == "debug"
      assert Map.has_key?(session.pending_requests, "req_1")
    end

    test "lists active sessions" do
      # Create multiple sessions
      session_ids = ["session_a", "session_b", "session_c"]

      for session_id <- session_ids do
        MockSessionStore.save(session_id, %{id: session_id}, [])
      end

      # List active sessions
      {:ok, active} = MockSessionStore.list_active([])
      assert length(active) == 3
      assert Enum.all?(session_ids, &(&1 in active))
    end

    test "deletes sessions from store" do
      session_id = "delete_session_222"

      # Save a session
      :ok = MockSessionStore.save(session_id, %{id: session_id}, [])

      # Verify it exists
      assert {:ok, _} = MockSessionStore.load(session_id, [])

      # Delete it
      :ok = MockSessionStore.delete(session_id, [])

      # Verify it's gone
      assert {:error, :not_found} = MockSessionStore.load(session_id, [])
    end
  end

  describe "session recovery on supervisor startup" do
    setup do
      # Start a test registry
      {:ok, _} = Registry.start_link(keys: :unique, name: Anubis.Server.Session.StoreTest.TestRegistry)
      :ok
    end

    defmodule TestRegistry do
      @moduledoc false
      alias Anubis.Server.Session.StoreTest.TestRegistry

      def supervisor(:session_supervisor, _server), do: {:via, Registry, {TestRegistry, :supervisor}}
      def server_session(_server, session_id), do: {:via, Registry, {TestRegistry, {:session, session_id}}}

      def whereis_server_session(_server, session_id) do
        case Registry.lookup(TestRegistry, {:session, session_id}) do
          [{pid, _}] -> pid
          [] -> nil
        end
      end
    end

    test "supervisor restores sessions on startup" do
      # Pre-populate store with sessions
      session_ids = ["restored_1", "restored_2"]

      for session_id <- session_ids do
        MockSessionStore.save(
          session_id,
          %{
            id: session_id,
            initialized: true,
            protocol_version: "2024-11-21"
          },
          []
        )
      end

      # Start the supervisor (this should restore sessions)
      {:ok, _sup} =
        SessionSupervisor.start_link(
          server: TestServer,
          registry: TestRegistry
        )

      # Wait a bit for sessions to be restored
      Process.sleep(100)

      # Verify sessions were restored
      for session_id <- session_ids do
        pid = TestRegistry.whereis_server_session(TestServer, session_id)
        assert is_pid(pid)

        # Get the session and verify it has restored data
        session_name = TestRegistry.server_session(TestServer, session_id)
        session = Session.get(session_name)
        assert session.id == session_id
        assert session.initialized == true
      end
    end
  end

  describe "session store configuration" do
    test "works without store configured" do
      # Remove store configuration
      Application.delete_env(:anubis_mcp, :session_store)

      session_id = "no_store_session"
      {:ok, _} = Registry.start_link(keys: :unique, name: TestSessionRegistry5)
      session_name = {:via, Registry, {TestSessionRegistry5, session_id}}

      # Should still be able to create sessions
      {:ok, _pid} =
        Session.start_link(
          session_id: session_id,
          name: session_name,
          server_module: TestServer
        )

      # Session should work normally
      Session.mark_initialized(session_name)
      session = Session.get(session_name)
      assert session.initialized == true
    end
  end
end
