defmodule Anubis.Server.TaskStore.Local do
  @moduledoc """
  In-memory `Anubis.Server.TaskStore` adapter backed by a single GenServer.

  Holds a `%{session_id => %{task_id => Task.t()}}` map. Suitable for STDIO
  transports and most HTTP deployments running on a single node. Tasks are lost
  on process restart — that's an accepted Phase 1 limitation; persistent
  storage will arrive via a future adapter.
  """

  @behaviour Anubis.Server.TaskStore

  use GenServer

  alias Anubis.Server.Task
  alias Anubis.Server.TaskStore

  @type state :: %{optional(String.t()) => %{optional(String.t()) => Task.t()}}

  @impl TaskStore
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Starts the local task store.

  ## Options

    * `:name` — registered process name (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @impl TaskStore
  def put(name, session_id, %Task{} = task) when is_binary(session_id) do
    GenServer.call(name, {:put, session_id, task})
  end

  @impl TaskStore
  def get(name, session_id, task_id) when is_binary(session_id) and is_binary(task_id) do
    GenServer.call(name, {:get, session_id, task_id})
  end

  @impl TaskStore
  def update(name, session_id, task_id, fun) when is_function(fun, 1) do
    GenServer.call(name, {:update, session_id, task_id, fun})
  end

  @impl TaskStore
  def delete(name, session_id, task_id) do
    GenServer.call(name, {:delete, session_id, task_id})
  end

  @impl TaskStore
  def list_by_session(name, session_id) do
    GenServer.call(name, {:list_by_session, session_id})
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:put, session_id, %Task{id: task_id} = task}, _from, state) do
    session_tasks = Map.get(state, session_id, %{})
    state = Map.put(state, session_id, Map.put(session_tasks, task_id, task))
    {:reply, :ok, state}
  end

  def handle_call({:get, session_id, task_id}, _from, state) do
    case state |> Map.get(session_id, %{}) |> Map.fetch(task_id) do
      {:ok, task} -> {:reply, {:ok, task}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update, session_id, task_id, fun}, _from, state) do
    session_tasks = Map.get(state, session_id, %{})

    case Map.fetch(session_tasks, task_id) do
      {:ok, task} ->
        updated = fun.(task)
        state = Map.put(state, session_id, Map.put(session_tasks, task_id, updated))
        {:reply, {:ok, updated}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, session_id, task_id}, _from, state) do
    session_tasks = Map.get(state, session_id, %{})
    state = Map.put(state, session_id, Map.delete(session_tasks, task_id))
    {:reply, :ok, state}
  end

  def handle_call({:list_by_session, session_id}, _from, state) do
    tasks = state |> Map.get(session_id, %{}) |> Map.values()
    {:reply, tasks, state}
  end
end
