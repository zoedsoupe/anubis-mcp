defmodule Anubis.Server.Registry.PGTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Registry.PG

  # Each test gets a unique registry name so the derived :pg scope is unique.
  # async: false because :pg scopes are node-global; unique names prevent
  # collisions but we still avoid async to keep process-exit timing predictable.
  setup ctx do
    name = :"test_registry_pg_#{ctx.test}"
    start_supervised!(PG.child_spec(name: name))
    %{name: name}
  end

  describe "child_spec/1" do
    test "returns a worker child spec that starts a :pg scope", %{name: name} do
      spec = PG.child_spec(name: name)

      assert spec.type == :worker
      assert spec.restart == :permanent
      assert {mod, _fun, _args} = spec.start
      assert mod == :pg
    end

    test "scopes are isolated per registry name" do
      name_a = :"test_registry_pg_isolation_a_#{System.unique_integer()}"
      name_b = :"test_registry_pg_isolation_b_#{System.unique_integer()}"

      start_supervised!({PG, name: name_a}, id: :pg_a)
      start_supervised!({PG, name: name_b}, id: :pg_b)

      session_id = "session-#{System.unique_integer()}"
      :ok = PG.register_session(name_a, session_id, self())

      assert {:ok, _pid} = PG.lookup_session(name_a, session_id)
      assert {:error, :not_found} = PG.lookup_session(name_b, session_id)
    end
  end

  describe "register_session/3 and lookup_session/2" do
    test "registered pid is found by lookup", %{name: name} do
      session_id = "session-#{System.unique_integer()}"

      assert :ok = PG.register_session(name, session_id, self())
      assert {:ok, pid} = PG.lookup_session(name, session_id)
      assert pid == self()
    end

    test "unregistered session_id returns not_found", %{name: name} do
      assert {:error, :not_found} = PG.lookup_session(name, "nonexistent-session")
    end

    test "multiple sessions are tracked independently", %{name: name} do
      session_a = "session-a-#{System.unique_integer()}"
      session_b = "session-b-#{System.unique_integer()}"

      pid_a = spawn(fn -> Process.sleep(:infinity) end)
      pid_b = spawn(fn -> Process.sleep(:infinity) end)

      :ok = PG.register_session(name, session_a, pid_a)
      :ok = PG.register_session(name, session_b, pid_b)

      assert {:ok, ^pid_a} = PG.lookup_session(name, session_a)
      assert {:ok, ^pid_b} = PG.lookup_session(name, session_b)
    end
  end

  describe "unregister_session/2" do
    test "unregistered session is no longer found", %{name: name} do
      session_id = "session-#{System.unique_integer()}"

      :ok = PG.register_session(name, session_id, self())
      assert {:ok, _pid} = PG.lookup_session(name, session_id)

      :ok = PG.unregister_session(name, session_id)
      assert {:error, :not_found} = PG.lookup_session(name, session_id)
    end

    test "unregistering a non-existent session is a no-op", %{name: name} do
      assert :ok = PG.unregister_session(name, "ghost-session")
    end
  end

  describe "automatic cleanup" do
    test "lookup returns not_found after session process exits", %{name: name} do
      session_id = "session-#{System.unique_integer()}"

      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = PG.register_session(name, session_id, pid)

      assert {:ok, ^pid} = PG.lookup_session(name, session_id)

      Process.exit(pid, :kill)
      # Allow :pg to process the DOWN message before asserting
      Process.sleep(50)

      assert {:error, :not_found} = PG.lookup_session(name, session_id)
    end
  end
end
