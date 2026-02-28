defmodule MockCustomRegistry do
  @moduledoc false
  @behaviour Anubis.Server.Registry

  use GenServer

  @impl Anubis.Server.Registry
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @impl Anubis.Server.Registry
  def register_session(name, session_id, pid) do
    GenServer.call(name, {:register, session_id, pid})
  end

  @impl Anubis.Server.Registry
  def lookup_session(name, session_id) do
    GenServer.call(name, {:lookup, session_id})
  end

  @impl Anubis.Server.Registry
  def unregister_session(name, session_id) do
    GenServer.call(name, {:unregister, session_id})
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{sessions: %{}}}
  end

  @impl GenServer
  def handle_call({:register, session_id, pid}, _from, state) do
    sessions = Map.put(state.sessions, session_id, pid)
    {:reply, :ok, %{state | sessions: sessions}}
  end

  def handle_call({:lookup, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil -> {:reply, {:error, :not_found}, state}
      pid -> {:reply, {:ok, pid}, state}
    end
  end

  def handle_call({:unregister, session_id}, _from, state) do
    sessions = Map.delete(state.sessions, session_id)
    {:reply, :ok, %{state | sessions: sessions}}
  end
end
