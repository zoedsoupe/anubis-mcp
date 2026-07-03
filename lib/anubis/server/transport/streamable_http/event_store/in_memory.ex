defmodule Anubis.Server.Transport.StreamableHTTP.EventStore.InMemory do
  @moduledoc """
  In-memory `Anubis.Server.Transport.StreamableHTTP.EventStore` adapter backed by
  a single GenServer.

  Each session keeps a bounded ring of the most recent `{event_id, data}` pairs.
  Event ids are drawn from a single store-wide monotonic counter, so they never
  restart at `1` for a session that was evicted and later reappears — a
  reconnect carrying an old higher `Last-Event-ID` therefore never filters out
  genuinely newer events. This is the default adapter and is suitable for
  single-node HTTP deployments: it makes short reconnect gaps seamless without
  any external dependency.

  ## Bounds

    * `:history_size` — events retained per session (default `100`). Older events
      are evicted; a client whose `Last-Event-ID` predates the ring recovers only
      the events still held (see the `EventStore` behaviour on gaps).
    * `:max_sessions` — sessions retained before the least-recently-appended one
      is evicted (default `1_000`, or `:infinity` to disable). This bounds memory
      for servers that churn sessions without an explicit `DELETE`. Sessions are
      also dropped promptly on `delete/2`. Because ids come from the store-wide
      counter, an evicted session that reappends resumes with strictly larger
      ids.

  Events are lost on process restart. Recovery across restarts is a host-level
  concern (e.g. a durable journal), by design: the transport ring exists to make
  live reconnects seamless, not to be a system of record.
  """

  @behaviour Anubis.Server.Transport.StreamableHTTP.EventStore

  use GenServer

  import Peri

  alias Anubis.Server.Transport.StreamableHTTP.EventStore

  @default_history_size 100
  @default_max_sessions 1_000

  defschema(:parse_options, [
    {:name, {:required, {:custom, &Anubis.genserver_name/1}}},
    {:history_size, {{:integer, {:gte, 1}}, {:default, @default_history_size}}},
    {:max_sessions, {{:either, {{:integer, {:gte, 1}}, {:literal, :infinity}}}, {:default, @default_max_sessions}}}
  ])

  @typep session :: %{seq: non_neg_integer(), events: [{non_neg_integer(), binary()}], touch: non_neg_integer()}
  @typep state :: %{
           history_size: pos_integer(),
           max_sessions: pos_integer() | :infinity,
           clock: non_neg_integer(),
           sessions: %{optional(String.t()) => session()}
         }

  @impl EventStore
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Starts the in-memory event store.

  ## Options

    * `:name` — registered process name (required)
    * `:history_size` — events retained per session (default `#{@default_history_size}`)
    * `:max_sessions` — sessions retained before LRU eviction, or `:infinity`
      (default `#{@default_max_sessions}`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = parse_options!(opts)
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @impl EventStore
  def append(name, session_id, data) when is_binary(session_id) and is_binary(data) do
    GenServer.call(name, {:append, session_id, data})
  end

  @impl EventStore
  def replay(name, session_id, after_id) when is_binary(session_id) and is_integer(after_id) and after_id >= 0 do
    GenServer.call(name, {:replay, session_id, after_id})
  end

  @impl EventStore
  def latest_id(name, session_id) when is_binary(session_id) do
    GenServer.call(name, {:latest_id, session_id})
  end

  @impl EventStore
  def delete(name, session_id) when is_binary(session_id) do
    GenServer.call(name, {:delete, session_id})
  end

  @impl GenServer
  @spec init(map()) :: {:ok, state(), :hibernate}
  def init(opts) do
    state = %{
      history_size: opts.history_size,
      max_sessions: opts.max_sessions,
      clock: 0,
      sessions: %{}
    }

    {:ok, state, :hibernate}
  end

  @impl GenServer
  def handle_call({:append, session_id, data}, _from, state) do
    # Ids come from the store-wide monotonic counter, not a per-session one, so
    # they stay strictly increasing for a session even across LRU eviction and
    # reappearance (the behaviour's "the store owns the counter" contract).
    id = state.clock + 1
    session = Map.get(state.sessions, session_id, %{seq: 0, events: [], touch: 0})

    events = Enum.take(session.events ++ [{id, data}], -state.history_size)
    session = %{seq: id, events: events, touch: id}

    sessions =
      state.sessions
      |> Map.put(session_id, session)
      |> evict_sessions(state.max_sessions)

    {:reply, {:ok, id}, %{state | sessions: sessions, clock: id}}
  end

  def handle_call({:replay, session_id, after_id}, _from, state) do
    events =
      case Map.get(state.sessions, session_id) do
        nil -> []
        %{events: events} -> Enum.filter(events, fn {id, _data} -> id > after_id end)
      end

    {:reply, {:ok, events}, state}
  end

  def handle_call({:latest_id, session_id}, _from, state) do
    seq =
      case Map.get(state.sessions, session_id) do
        nil -> 0
        %{seq: seq} -> seq
      end

    {:reply, {:ok, seq}, state}
  end

  def handle_call({:delete, session_id}, _from, state) do
    {:reply, :ok, %{state | sessions: Map.delete(state.sessions, session_id)}}
  end

  @impl GenServer
  def terminate(_reason, _state), do: :ok

  # Drops the least-recently-appended session when the session count exceeds the
  # cap. At most one session is added per append, so evicting one restores the
  # bound. The just-appended session carries the highest `touch` and is safe.
  @spec evict_sessions(map(), pos_integer() | :infinity) :: map()
  defp evict_sessions(sessions, :infinity), do: sessions

  defp evict_sessions(sessions, max_sessions) when map_size(sessions) > max_sessions do
    {oldest, _session} = Enum.min_by(sessions, fn {_id, %{touch: touch}} -> touch end)
    Map.delete(sessions, oldest)
  end

  defp evict_sessions(sessions, _max_sessions), do: sessions
end
