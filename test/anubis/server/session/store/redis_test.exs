if Code.ensure_loaded?(Redix) do
  defmodule Anubis.Server.Session.Store.RedisTest do
    # Regression coverage for the {:already_started} crash observed when the
    # store restarted under the server's :one_for_all supervisor. The store is
    # now a supervised subtree (pool + state server), so a restart tears the
    # whole tree down synchronously and no fixed name is ever double-registered.
    #
    # Redix starts with sync_connect: false, so the subtree starts without a live
    # Redis — these run deterministically outside the :integration suite.
    use ExUnit.Case, async: false

    alias Anubis.Server.Session.Store.Redis

    @moduletag capture_log: true

    setup do
      conn_name = :"redis_test_#{System.unique_integer([:positive])}"

      config = [
        redis_url: "redis://localhost:6379",
        pool_size: 2,
        ttl: 10_000,
        namespace: "anubis:test",
        connection_name: conn_name
      ]

      %{conn_name: conn_name, config: config}
    end

    describe "supervision structure" do
      test "starts the pool and state server as supervised children", %{config: config} do
        sup = start_supervised!({Redis, config})
        assert Process.alive?(sup)

        children = Supervisor.which_children(sup)

        # pool_size connections + one state server
        assert length(children) == config[:pool_size] + 1

        assert Enum.all?(children, fn {_id, pid, _type, _mods} ->
                 is_pid(pid) and Process.alive?(pid)
               end)

        assert Enum.any?(children, fn {id, _pid, _type, _mods} -> id == Redis.Server end)
        assert is_pid(Process.whereis(Redis.Server))
      end
    end

    describe ":one_for_all restart cascade" do
      test "store subtree is replaced by a fresh instance when a sibling crashes", %{config: config} do
        {:ok, parent} =
          Supervisor.start_link(
            [
              %{id: :sibling, start: {Agent, :start_link, [fn -> 0 end]}},
              {Redis, config}
            ],
            strategy: :one_for_all
          )

        on_exit(fn -> stop_supervisor(parent) end)

        store_before = wait_for_pid(Redis)
        ref = Process.monitor(store_before)

        sibling = child_pid(parent, :sibling)
        Process.exit(sibling, :kill)

        # :one_for_all restarts every child, so the store subtree is torn down...
        assert_receive {:DOWN, ^ref, :process, ^store_before, _}, 2_000

        # ...and replaced by a distinct, live instance — no {:already_started}.
        store_after = wait_for_new_pid(Redis, store_before)
        assert store_after != store_before
        assert Process.alive?(store_after)
        assert Process.alive?(parent)
      end
    end

    describe "behaviour delegation" do
      test "cleanup_expired/1 reaches the state server without Redis", %{config: config} do
        start_supervised!({Redis, config})
        assert {:ok, 0} = Redis.cleanup_expired([])
      end
    end

    describe "post-restart round-trip" do
      @describetag :integration

      @tag :integration
      test "persisted sessions are served by the restarted pool", %{config: config} do
        namespace = config[:namespace]

        on_exit(fn ->
          {:ok, conn} = Redix.start_link(config[:redis_url])

          try do
            case Redix.command(conn, ["KEYS", "#{namespace}:*"]) do
              {:ok, [_ | _] = keys} -> Redix.command(conn, ["DEL" | keys])
              _ -> :ok
            end
          after
            Redix.stop(conn)
          end
        end)

        {:ok, parent} =
          Supervisor.start_link(
            [
              %{id: :sibling, start: {Agent, :start_link, [fn -> 0 end]}},
              {Redis, config}
            ],
            strategy: :one_for_all
          )

        on_exit(fn -> stop_supervisor(parent) end)

        wait_for_pid(Redis)
        session_id = "roundtrip_#{System.unique_integer([:positive])}"
        assert :ok = eventually_ok(fn -> Redis.save(session_id, %{id: session_id}) end)

        store_before = wait_for_pid(Redis)
        Process.exit(child_pid(parent, :sibling), :kill)
        wait_for_new_pid(Redis, store_before)

        # The data lives in Redis; the freshly restarted pool must still serve it.
        assert {:ok, %{"id" => ^session_id}} = eventually_ok(fn -> Redis.load(session_id) end)
      end
    end

    defp stop_supervisor(pid) do
      Supervisor.stop(pid)
    catch
      :exit, _ -> :ok
    end

    defp child_pid(sup, id) do
      {^id, pid, _type, _mods} =
        Enum.find(Supervisor.which_children(sup), fn {child_id, _, _, _} -> child_id == id end)

      pid
    end

    defp wait_for_pid(name, retries \\ 50) do
      case Process.whereis(name) do
        pid when is_pid(pid) ->
          pid

        nil when retries > 0 ->
          Process.sleep(20)
          wait_for_pid(name, retries - 1)

        nil ->
          flunk("#{inspect(name)} was never registered")
      end
    end

    defp wait_for_new_pid(name, old_pid, retries \\ 50) do
      case Process.whereis(name) do
        pid when is_pid(pid) and pid != old_pid ->
          pid

        _ when retries > 0 ->
          Process.sleep(20)
          wait_for_new_pid(name, old_pid, retries - 1)

        _ ->
          flunk("#{inspect(name)} was not replaced with a new pid")
      end
    end

    defp eventually_ok(fun, retries \\ 25) do
      case fun.() do
        {:error, _} when retries > 0 ->
          Process.sleep(40)
          eventually_ok(fun, retries - 1)

        other ->
          other
      end
    end
  end
end
