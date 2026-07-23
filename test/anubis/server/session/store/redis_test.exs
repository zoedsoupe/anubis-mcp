if Code.ensure_loaded?(Redix) do
  defmodule Anubis.Server.Session.Store.RedisTest do
    # Regression coverage for the {:already_started} crash observed when the
    # store restarts under the server's :one_for_all supervisor. Redix starts
    # with sync_connect: false, so the store starts without a live Redis, which
    # lets these run deterministically outside the :integration suite.
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

    describe "start_link/1 idempotency" do
      test "adopts the live instance instead of crashing on {:already_started}", %{config: config} do
        pid1 = start_supervised!({Redis, config})
        assert Process.alive?(pid1)

        # A second start under the same global name must not crash; it adopts
        # the already-registered process.
        assert {:ok, ^pid1} = Redis.start_link(config)
        assert Process.alive?(pid1)
      end
    end

    describe "init/1 pool supervisor collision" do
      test "reuses a pre-registered pool supervisor instead of stopping", %{
        conn_name: conn_name,
        config: config
      } do
        supervisor_name = :"anubis_#{conn_name}_supervisor"

        # Simulate the racing restart: the prior pool supervisor's fixed name is
        # still taken when the new store's init/1 runs.
        {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one, name: supervisor_name)

        on_exit(fn ->
          if Process.alive?(sup), do: Supervisor.stop(sup)
        end)

        # Before the fix this returned {:stop, {:error, {:already_started, _}}}
        # and the child failed to start. Now it starts and reuses the pool.
        pid = start_supervised!({Redis, config})
        assert Process.alive?(pid)

        # A Redis-free call confirms the GenServer is live and answering.
        assert {:ok, 0} = Redis.cleanup_expired([])
      end
    end

    describe ":one_for_all restart cascade" do
      test "store survives a sibling crash without an {:already_started} failure", %{config: config} do
        {:ok, sup} =
          Supervisor.start_link(
            [
              %{id: :sibling, start: {Agent, :start_link, [fn -> 0 end]}},
              {Redis, config}
            ],
            strategy: :one_for_all
          )

        on_exit(fn ->
          if Process.alive?(sup), do: Supervisor.stop(sup)
        end)

        store_before = Process.whereis(Redis)
        assert is_pid(store_before)

        [{_, sibling_pid, _, _}] =
          Enum.filter(Supervisor.which_children(sup), fn {id, _, _, _} -> id == :sibling end)

        ref = Process.monitor(sibling_pid)
        Process.exit(sibling_pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^sibling_pid, _}, 1_000

        # :one_for_all restarts every child, including the store. Its restart
        # must succeed (fresh pid, re-registered name) rather than flapping on
        # {:already_started}.
        assert eventually(fn ->
                 case Process.whereis(Redis) do
                   pid when is_pid(pid) -> Process.alive?(pid)
                   _ -> false
                 end
               end)

        assert Process.alive?(sup)
      end
    end

    defp eventually(fun, retries \\ 50) do
      cond do
        fun.() ->
          true

        retries <= 0 ->
          false

        true ->
          Process.sleep(20)
          eventually(fun, retries - 1)
      end
    end
  end
end
