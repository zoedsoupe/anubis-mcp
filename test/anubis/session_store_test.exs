defmodule Anubis.Server.SessionStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Anubis.Server.Supervisor
  alias Anubis.Test.MockSessionStore

  setup do
    original = Application.get_env(:anubis_mcp, :session_store)
    on_exit(fn -> Application.put_env(:anubis_mcp, :session_store, original) end)
    :ok
  end

  describe "resolve_session_store/1" do
    test "falls back to the global config when the server sets nothing" do
      Application.put_env(:anubis_mcp, :session_store, enabled: true, adapter: MockSessionStore, ttl: 60)

      assert {MockSessionStore, config} = Anubis.resolve_session_store([])
      assert config[:ttl] == 60
    end

    test "returns nil when neither the server nor the global config sets one" do
      Application.delete_env(:anubis_mcp, :session_store)

      assert Anubis.resolve_session_store([]) == nil
    end

    test "a server option wins over the global config" do
      Application.put_env(:anubis_mcp, :session_store, enabled: true, adapter: NonExisting.Adapter)

      assert {MockSessionStore, [namespace: "tenant"]} =
               Anubis.resolve_session_store(session_store: {MockSessionStore, namespace: "tenant"})
    end

    test "a bare module gets empty opts" do
      assert {MockSessionStore, []} = Anubis.resolve_session_store(session_store: MockSessionStore)
    end

    test "false disables the store for one server while another still uses it" do
      Application.put_env(:anubis_mcp, :session_store, enabled: true, adapter: MockSessionStore)

      assert Anubis.resolve_session_store(session_store: false) == nil
      assert {MockSessionStore, _config} = Anubis.resolve_session_store([])
    end
  end

  describe "session_store_children/1" do
    test "returns no children without a store" do
      assert [] == Supervisor.session_store_children(nil)
    end

    test "logs a warning when the adapter is not available" do
      log =
        capture_log(fn ->
          assert [] == Supervisor.session_store_children({NonExisting.Adapter, []})
        end)

      assert log =~ "Session store adapter not available"
    end

    test "returns a child spec when the adapter is available" do
      config = [enabled: true, adapter: MockSessionStore, ttl: 1_800_000, namespace: "anubis:sessions"]

      assert [{MockSessionStore, returned_config}] = Supervisor.session_store_children({MockSessionStore, config})
      assert returned_config == config
    end
  end
end
