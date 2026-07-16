defmodule Anubis.Server.SessionExpiryTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.MCP.Error
  alias Anubis.Server.Registry
  alias Anubis.Server.Session
  alias Anubis.Test.MockSessionStore

  @moduletag capture_log: true

  defp start_session(server_module, session_id, extra_opts \\ []) do
    transport_name = Registry.transport_name(server_module, StubTransport)
    task_sup = Registry.task_supervisor_name(server_module)
    session_name = Registry.session_name(server_module, session_id)

    start_supervised!({StubTransport, name: transport_name}, id: :"transport_#{session_id}")
    start_supervised!({Task.Supervisor, name: task_sup}, id: :"task_sup_#{session_id}")

    opts =
      [
        session_id: session_id,
        server_module: server_module,
        name: session_name,
        transport: [layer: StubTransport, name: transport_name],
        task_supervisor: task_sup
      ] ++ extra_opts

    start_supervised!({Session, opts}, id: :"session_#{session_id}")
  end

  describe "auto_initialize/1 default behavior" do
    test "marks session as initialized with synthetic client info" do
      session_id = "auto-init-default-#{System.unique_integer([:positive])}"
      session = start_session(StubServer, session_id)

      assert :ok = Session.auto_initialize(session)

      state = :sys.get_state(session)
      assert state.initialized
      assert state.client_info == %{"name" => "auto-recovered", "version" => "unknown"}
    end

    test "is idempotent when already initialized" do
      session_id = "auto-init-idempotent-#{System.unique_integer([:positive])}"
      session = start_session(StubServer, session_id)

      assert :ok = Session.auto_initialize(session)
      assert :ok = Session.auto_initialize(session)

      state = :sys.get_state(session)
      assert state.initialized
    end
  end

  describe "auto_initialize/1 with session store" do
    setup do
      {:ok, _} = MockSessionStore.start_link([])
      MockSessionStore.reset!()

      Application.put_env(:anubis_mcp, :session_store,
        enabled: true,
        adapter: MockSessionStore
      )

      on_exit(fn -> Application.delete_env(:anubis_mcp, :session_store) end)

      :ok
    end

    test "restores client_info and frame assigns from store" do
      session_id = "store-restore-#{System.unique_integer([:positive])}"

      saved_client_info = %{"name" => "real-client", "version" => "2.0"}

      MockSessionStore.save(
        session_id,
        %{
          "id" => session_id,
          "client_info" => saved_client_info,
          "frame" => %{"assigns" => %{"key" => "value"}, "pagination_limit" => nil}
        },
        []
      )

      session = start_session(StubServer, session_id)

      assert :ok = Session.auto_initialize(session)

      state = :sys.get_state(session)
      assert state.client_info == saved_client_info
      # assigns come back from store with string keys (JSON serialization round-trip)
      assert state.frame.assigns["key"] == "value"
    end

    test "falls back to synthetic client_info when store has no entry" do
      session_id = "store-miss-#{System.unique_integer([:positive])}"
      session = start_session(StubServer, session_id)

      assert :ok = Session.auto_initialize(session)

      state = :sys.get_state(session)
      assert state.client_info == %{"name" => "auto-recovered", "version" => "unknown"}
    end
  end

  describe "handle_session_expired/2 callback" do
    test "callback receives session_id and frame, can return custom client_info" do
      session_id = "expiry-cb-#{System.unique_integer([:positive])}"
      session = start_session(StubSessionRecoveryServer, session_id)

      assert :ok = Session.auto_initialize(session)

      state = :sys.get_state(session)
      assert state.initialized
      assert state.client_info == %{"name" => "recovered-client", "version" => "1.0"}
      assert state.frame.assigns[:recovery_ran] == true
    end

    test "callback returning {:error, reason} causes auto_initialize to fail" do
      session_id = "expiry-reject-#{System.unique_integer([:positive])}"
      session = start_session(StubSessionRecoveryRejectServer, session_id)

      assert {:error, %Error{reason: :internal_error, data: %{message: _}}} =
               Session.auto_initialize(session)

      state = :sys.get_state(session)
      refute state.initialized
    end
  end

  describe "auto_initialize/2 threads request context" do
    test "recovered frame carries live request assigns (no store)" do
      session_id = "auto-ctx-assigns-#{System.unique_integer([:positive])}"
      session = start_session(StubSessionRecoveryServer, session_id)

      context = %{assigns: %{current_user: %{id: 7}}, type: :http}

      assert :ok = Session.auto_initialize(session, context)

      state = :sys.get_state(session)
      assert state.frame.assigns[:seen_assigns][:current_user] == %{id: 7}
      assert state.frame.assigns[:current_user] == %{id: 7}
    end

    test "recovered frame.context carries headers, remote_ip and auth" do
      session_id = "auto-ctx-context-#{System.unique_integer([:positive])}"
      session = start_session(StubSessionRecoveryServer, session_id)

      context = %{
        assigns: %{},
        type: :http,
        req_headers: [{"authorization", "Bearer abc"}],
        remote_ip: {127, 0, 0, 1},
        auth: %{"sub" => "user-7"}
      }

      assert :ok = Session.auto_initialize(session, context)

      state = :sys.get_state(session)
      seen = state.frame.assigns[:seen_context]
      assert seen.headers["authorization"] == "Bearer abc"
      assert seen.remote_ip == {127, 0, 0, 1}
      assert seen.auth == %{"sub" => "user-7"}
    end

    test "backwards-compat: auto_initialize/1 still works with empty assigns" do
      session_id = "auto-ctx-compat-#{System.unique_integer([:positive])}"
      session = start_session(StubServer, session_id)

      assert :ok = Session.auto_initialize(session)

      state = :sys.get_state(session)
      assert state.initialized
      assert state.frame.assigns == %{}
    end

    test "live assigns replace stale store assigns (string-vs-atom key divergence)" do
      {:ok, _} = MockSessionStore.start_link([])
      MockSessionStore.reset!()

      Application.put_env(:anubis_mcp, :session_store, enabled: true, adapter: MockSessionStore)
      on_exit(fn -> Application.delete_env(:anubis_mcp, :session_store) end)

      session_id = "auto-ctx-store-#{System.unique_integer([:positive])}"

      MockSessionStore.save(
        session_id,
        %{
          "id" => session_id,
          "client_info" => %{"name" => "real-client", "version" => "2.0"},
          "frame" => %{
            "assigns" => %{"current_user" => %{"id" => "stale"}},
            "pagination_limit" => nil
          }
        },
        []
      )

      session = start_session(StubSessionRecoveryServer, session_id)

      context = %{assigns: %{current_user: %{id: 7}}, type: :http}
      assert :ok = Session.auto_initialize(session, context)

      state = :sys.get_state(session)
      assert state.frame.assigns[:current_user] == %{id: 7}
      refute Map.has_key?(state.frame.assigns, "current_user")
    end

    test "store-only recovery preserved when request carries no assigns" do
      {:ok, _} = MockSessionStore.start_link([])
      MockSessionStore.reset!()

      Application.put_env(:anubis_mcp, :session_store, enabled: true, adapter: MockSessionStore)
      on_exit(fn -> Application.delete_env(:anubis_mcp, :session_store) end)

      session_id = "auto-ctx-store-only-#{System.unique_integer([:positive])}"

      MockSessionStore.save(
        session_id,
        %{
          "id" => session_id,
          "client_info" => %{"name" => "real-client", "version" => "2.0"},
          "frame" => %{"assigns" => %{"key" => "value"}, "pagination_limit" => nil}
        },
        []
      )

      session = start_session(StubSessionRecoveryServer, session_id)

      assert :ok = Session.auto_initialize(session, %{assigns: %{}, type: :http})

      state = :sys.get_state(session)
      assert state.frame.assigns["key"] == "value"
    end
  end

  describe "init/2 callback" do
    test "callback returning {:error, reason} causes auto_initialize to fail with encodable error" do
      session_id = "init-reject-#{System.unique_integer([:positive])}"
      session = start_session(StubInitRejectServer, session_id)

      assert {:error, %Error{reason: :internal_error, data: %{message: message}}} =
               Session.auto_initialize(session)

      assert is_binary(message)
      refute String.contains?(message, "init_failed")

      state = :sys.get_state(session)
      refute state.initialized
    end
  end
end
