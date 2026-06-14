defmodule Anubis.Server.RegistryTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Registry

  # A registry adapter that does NOT implement the optional session_name/2
  # callback, so resolve_session_name/3 takes the default naming path. This is
  # the path the shipped Registry.Local and Registry.PG adapters hit in
  # production.
  defmodule AdapterWithoutSessionName do
    @moduledoc false
    @behaviour Registry

    @impl true
    def child_spec(_opts), do: :ignore
    @impl true
    def register_session(_name, _session_id, _pid), do: :ok
    @impl true
    def lookup_session(_name, _session_id), do: {:error, :not_found}
    @impl true
    def unregister_session(_name, _session_id), do: :ok
  end

  describe "resolve_session_name/3" do
    setup do
      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      naming_registry = Registry.naming_registry_name(registry_name)
      start_supervised!({Elixir.Registry, keys: :unique, name: naming_registry})
      %{registry_name: registry_name, naming_registry: naming_registry}
    end

    test "returns a :via Registry name rather than minting an atom", ctx do
      name =
        Registry.resolve_session_name(
          AdapterWithoutSessionName,
          ctx.registry_name,
          "client-supplied-session-id"
        )

      assert {:via, Elixir.Registry, {naming_registry, "client-supplied-session-id"}} = name
      assert naming_registry == ctx.naming_registry
    end

    test "names a process that can be addressed and looked up by session id", ctx do
      name =
        Registry.resolve_session_name(
          AdapterWithoutSessionName,
          ctx.registry_name,
          "session-abc"
        )

      {:ok, pid} = Agent.start_link(fn -> :state end, name: name)

      assert [{^pid, _}] = Elixir.Registry.lookup(ctx.naming_registry, "session-abc")
      assert :state = Agent.get(name, & &1)

      Agent.stop(pid)
    end

    test "concurrent starts for the same session id yield {:already_started, pid}", ctx do
      name =
        Registry.resolve_session_name(AdapterWithoutSessionName, ctx.registry_name, "dup-session")

      {:ok, pid} = Agent.start_link(fn -> :ok end, name: name)

      assert {:error, {:already_started, ^pid}} =
               Agent.start(fn -> :ok end, name: name)

      Agent.stop(pid)
    end

    # Regression test for the atom-table exhaustion DoS. Session ids come from
    # the client-controlled mcp-session-id header. The previous implementation
    # built :"#{registry_name}.session.#{session_id}" per session id; atoms are
    # never garbage collected, so distinct session ids grew the atom table
    # without bound and a client could crash the VM. The :via Registry name is
    # keyed by the session-id *string*, so no new atoms are created per session.
    test "does not grow the atom table across many distinct session ids", ctx do
      # Warm up the code path once so any one-time atoms (module/function
      # resolution) are already interned before we take the baseline.
      _ = Registry.resolve_session_name(AdapterWithoutSessionName, ctx.registry_name, "warmup")

      :erlang.garbage_collect()
      before_count = :erlang.system_info(:atom_count)

      for i <- 1..50_000 do
        session_id = "sess-#{i}-#{:erlang.unique_integer([:positive])}"

        {:via, Elixir.Registry, {_naming, ^session_id}} =
          Registry.resolve_session_name(AdapterWithoutSessionName, ctx.registry_name, session_id)
      end

      after_count = :erlang.system_info(:atom_count)
      growth = after_count - before_count

      assert growth < 100,
             "atom table grew by #{growth} across 50_000 distinct session ids " <>
               "(before=#{before_count}, after=#{after_count}); session naming is " <>
               "minting an atom per session id"
    end
  end

  describe "naming_registry_name/1" do
    test "derives a stable atom from a compile-time bounded registry name" do
      assert Registry.naming_registry_name(:"Anubis.MyServer.registry") ==
               :"Anubis.MyServer.registry.names"
    end
  end
end
