defmodule Anubis.Server.Registry.Local do
  @moduledoc """
  ETS-based session registry for HTTP transports.

  Uses a named ETS table with `read_concurrency: true` for fast lookups.
  Monitors registered processes for automatic cleanup on crash/shutdown.
  """

  @behaviour Anubis.Server.Registry

  use GenServer

  @impl Anubis.Server.Registry
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Anubis.Server.Registry
  def register_session(name, session_id, pid) do
    GenServer.call(name, {:register, session_id, pid})
  end

  @impl Anubis.Server.Registry
  def lookup_session(name, session_id) do
    table = table_name(name)

    case :ets.lookup(table, session_id) do
      [{^session_id, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}

      [] ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @impl Anubis.Server.Registry
  def unregister_session(name, session_id) do
    GenServer.call(name, {:unregister, session_id})
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = table_name(name)
    ^table = :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

    {:ok, %{table: table, monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:register, session_id, pid}, _from, state) do
    :ets.insert(state.table, {session_id, pid})
    ref = Process.monitor(pid)
    monitors = Map.put(state.monitors, ref, session_id)
    {:reply, :ok, %{state | monitors: monitors}}
  end

  def handle_call({:unregister, session_id}, _from, state) do
    :ets.delete(state.table, session_id)

    monitors =
      state.monitors
      |> Enum.reject(fn {_ref, sid} -> sid == session_id end)
      |> Map.new()

    {:reply, :ok, %{state | monitors: monitors}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {session_id, monitors} ->
        :ets.delete(state.table, session_id)
        {:noreply, %{state | monitors: monitors}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp table_name(name) when is_atom(name), do: :"#{name}.ets"
end
