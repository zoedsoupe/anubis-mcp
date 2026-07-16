defmodule Anubis.Server.Transport.StreamableHTTP do
  @moduledoc """
  StreamableHTTP transport implementation for MCP servers.

  This module manages SSE (Server-Sent Events) connections for server-to-client
  communication. In the refactored architecture, request handling is done directly
  by Session processes - this module only manages SSE handlers and notifications.

  ## Features

  - SSE handler registration for server-to-client push
  - Automatic handler cleanup on disconnect
  - Keepalive messages to maintain connections
  - Notification broadcasting to connected clients
  - Optional resumability: when an `:event_store` is configured, messages on a
    session's standalone stream are recorded with monotonic ids and replayed on
    reconnect via `Last-Event-ID`. Messages fired while no handler is attached
    are still recorded (bounded by `:stream_grace`), so they survive reconnect
    gaps. See `Anubis.Server.Transport.StreamableHTTP.EventStore`.

  ## Usage

  StreamableHTTP is typically started through the server supervisor:

      Anubis.Server.start_link(MyServer, [],
        transport: :streamable_http,
        streamable_http: [port: 4000]
      )

  For integration with existing Phoenix/Plug applications:

      # In your router
      forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug,
        server: MyApp.MCPServer
  """

  @behaviour Anubis.Transport.Behaviour

  use GenServer
  use Anubis.Logging

  import Peri

  alias Anubis.Telemetry
  alias Anubis.Transport.Behaviour, as: Transport

  @type t :: GenServer.server()

  @typedoc """
  StreamableHTTP transport options

  - `:server` - The server module (required)
  - `:name` - Name for registering the GenServer (required)
  """
  @type option ::
          {:server, GenServer.server()}
          | {:name, GenServer.name()}
          | GenServer.option()

  defschema(:parse_options, [
    {:server, {:required, Anubis.get_schema(:process_name)}},
    {:name, {:required, {:custom, &Anubis.genserver_name/1}}},
    {:registry, {:atom, {:default, Anubis.Server.Registry}}},
    {:task_supervisor, {:required, {:custom, &Anubis.genserver_name/1}}},
    {:keepalive, {:boolean, {:default, true}}},
    {:keepalive_interval, {{:integer, {:gte, 1}}, {:default, 5_000}}},
    {:event_store, {:any, {:default, nil}}},
    {:sse_retry, {{:integer, {:gte, 0}}, {:default, nil}}},
    {:stream_grace, {{:integer, {:gte, 0}}, {:default, 60_000}}}
  ])

  @impl Transport
  @spec start_link(Enumerable.t(option())) :: GenServer.on_start()
  def start_link(opts) do
    opts = parse_options!(opts)
    {name, opts} = Keyword.pop!(opts, :name)

    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @impl Transport
  def send_message(transport, message, opts) when is_binary(message) do
    GenServer.call(transport, {:send_message, message}, opts[:timeout])
  end

  @impl Transport
  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(transport) do
    GenServer.cast(transport, :shutdown)
  end

  @impl Transport
  def supported_protocol_versions, do: ["2025-03-26", "2025-06-18"]

  @doc """
  Registers the calling process as the SSE handler for a session.

  Called by the Plug when establishing an SSE connection. Equivalent to
  `register_sse_handler/3` with empty metadata.
  """
  @spec register_sse_handler(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def register_sse_handler(transport, session_id) do
    register_sse_handler(transport, session_id, %{})
  end

  @doc """
  Registers the calling process as the SSE handler for a session, attaching an
  opaque `metadata` map.

  The transport stores `metadata` verbatim and never interprets it. Hosts use it
  to tag a subscriber with application-defined attributes (tenant, user, feature
  scope, ...) so later `send_message_to_subscribers/4` and `handler_count/2` calls
  can select on them. The Plug populates it from its `:subscriber_metadata`
  callback; direct callers may pass any map.
  """
  @spec register_sse_handler(GenServer.server(), String.t(), map()) :: :ok | {:error, term()}
  def register_sse_handler(transport, session_id, metadata) when is_map(metadata) do
    GenServer.call(transport, {:register_sse_handler, session_id, self(), metadata}, 5000)
  end

  @doc """
  Unregisters the SSE handler for a session. Called when the SSE connection closes.
  """
  @spec unregister_sse_handler(GenServer.server(), String.t(), pid() | nil) :: :ok
  def unregister_sse_handler(transport, session_id, expected_pid \\ nil) do
    GenServer.cast(transport, {:unregister_sse_handler, session_id, expected_pid})
  end

  @doc """
  Returns the SSE handler pid for a session, or `nil` if none is connected.
  """
  @spec get_sse_handler(GenServer.server(), String.t()) :: pid() | nil
  def get_sse_handler(transport, session_id) do
    GenServer.call(transport, {:get_sse_handler, session_id})
  end

  @doc """
  Routes a message to a specific session's SSE handler for server-to-client push.

  When resumability is enabled the message is also recorded on the session's
  stream so it can be replayed on reconnect. The message is recorded even if no
  handler is currently attached, in which case `:ok` is still returned.
  """
  @spec route_to_session(GenServer.server(), String.t(), binary()) ::
          :ok | {:error, term()}
  def route_to_session(transport, session_id, message) do
    GenServer.call(transport, {:route_to_session, session_id, message})
  end

  @doc """
  Returns the resumability config for this transport as `{event_store, retry}`,
  where `event_store` is `{module, name}` or `nil` and `retry` is the SSE
  `retry:` value in milliseconds or `nil`. Read by the Plug when opening an SSE
  stream.
  """
  @spec resumability_config(GenServer.server()) :: {term() | nil, non_neg_integer() | nil}
  def resumability_config(transport) do
    GenServer.call(transport, :resumability_config)
  end

  @doc """
  Closes a session's resumable stream and drops its recorded events. Called on
  `DELETE` (explicit session termination). No-op when resumability is disabled.
  """
  @spec close_session_stream(GenServer.server(), String.t()) :: :ok
  def close_session_stream(transport, session_id) do
    GenServer.cast(transport, {:close_session_stream, session_id})
  end

  @doc
  Returns the number of connected SSE handlers.
  """
  @spec handler_count(GenServer.server()) :: non_neg_integer()
  def handler_count(transport) do
    GenServer.call(transport, :handler_count)
  end

  @doc """
  Returns the number of connected SSE handlers whose metadata satisfies `selector`.

  `selector` receives each handler's opaque metadata map (see
  `register_sse_handler/3`) and returns a truthy value to count that handler.
  """
  @spec handler_count(GenServer.server(), (map() -> as_boolean(term()))) :: non_neg_integer()
  def handler_count(transport, selector) when is_function(selector, 1) do
    GenServer.call(transport, {:handler_count, selector})
  end

  @doc """
  Sends a message to every connected SSE handler whose metadata satisfies `selector`.

  `selector` receives each handler's opaque metadata map (see
  `register_sse_handler/3`) and returns a truthy value for the subscribers that
  should receive `message`. This complements `route_to_session/3` (a single
  session) and `send_message/3` (broadcast to all handlers) with delivery to an
  arbitrary, application-defined subset.

  `opts` accepts `:timeout` (default `5000`).
  """
  @spec send_message_to_subscribers(
          GenServer.server(),
          (map() -> as_boolean(term())),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def send_message_to_subscribers(transport, selector, message, opts \\ [])
      when is_function(selector, 1) and is_binary(message) do
    GenServer.call(
      transport,
      {:send_message_to_subscribers, selector, message},
      Keyword.get(opts, :timeout, 5000)
    )
  end

  # GenServer implementation

  @impl GenServer
  def init(%{server: server} = opts) do
    Process.flag(:trap_exit, true)

    state = %{
      server: server,
      registry: opts.registry,
      task_supervisor: opts.task_supervisor,
      sse_handlers: %{},
      keepalive_interval: opts.keepalive_interval,
      keepalive_enabled: opts.keepalive,
      event_store: opts.event_store,
      sse_retry: opts.sse_retry,
      stream_grace: opts.stream_grace,
      streams: MapSet.new(),
      stream_timers: %{}
    }

    if should_keepalive?(state) do
      schedule_keepalive(state.keepalive_interval)
    end

    Logger.metadata(mcp_transport: :streamable_http, mcp_server: server)

    Logging.transport_event("starting", %{
      transport: :streamable_http,
      server: server
    })

    Telemetry.execute(
      Telemetry.event_transport_init(),
      %{system_time: System.system_time()},
      %{transport: :streamable_http, server: server}
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:register_sse_handler, session_id, pid, metadata}, _from, state) do
    sse_handlers =
      case Map.get(state.sse_handlers, session_id) do
        {_pid, old_ref, _meta} ->
          Process.demonitor(old_ref, [:flush])
          state.sse_handlers

        nil ->
          state.sse_handlers
      end

    ref = Process.monitor(pid)
    sse_handlers = Map.put(sse_handlers, session_id, {pid, ref, metadata})

    Logging.transport_event("sse_handler_registered", %{
      session_id: session_id,
      handler_pid: inspect(pid)
    })

    # Open the session's stream so broadcasts keep recording into it across
    # handler disconnects (the reconnect gap), and cancel any pending grace-close
    # timer since the client has reconnected.
    streams = open_stream(state, session_id)
    stream_timers = cancel_close_timer(state.stream_timers, session_id)

    new_state = %{state | sse_handlers: sse_handlers, streams: streams, stream_timers: stream_timers}

    # Start keepalive when first SSE handler is registered
    # This fixes the bug where keepalive never starts if server has no handlers at init
    if map_size(state.sse_handlers) == 0 and should_keepalive?(new_state) do
      schedule_keepalive(new_state.keepalive_interval)
    end

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:get_sse_handler, session_id}, _from, state) do
    case Map.get(state.sse_handlers, session_id) do
      {pid, _ref, _meta} -> {:reply, pid, state}
      nil -> {:reply, nil, state}
    end
  end

  @impl GenServer
  def handle_call({:route_to_session, session_id, message}, _from, state) do
    route(state, session_id, message)
  end

  @impl GenServer
  def handle_call(:handler_count, _from, state) do
    {:reply, map_size(state.sse_handlers), state}
  end

  @impl GenServer
  def handle_call({:handler_count, selector}, _from, state) do
    count =
      Enum.count(state.sse_handlers, fn {_session_id, {_pid, _ref, metadata}} ->
        selector.(metadata)
      end)

    {:reply, count, state}
  end

  @impl GenServer
  def handle_call({:send_message_to_subscribers, selector, message}, _from, state) do
    for {_session_id, {pid, _ref, metadata}} <- state.sse_handlers, selector.(metadata) do
      send(pid, {:sse_message, message})
    end

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:send_message, message}, _from, state) do
    Logging.transport_event("broadcast_notification", %{
      message_size: byte_size(message),
      active_handlers: map_size(state.sse_handlers)
    })

    {:reply, broadcast(state, message), state}
  end

  @impl GenServer
  def handle_call(:resumability_config, _from, state) do
    {:reply, {state.event_store, state.sse_retry}, state}
  end

  @impl GenServer
  def handle_cast({:unregister_sse_handler, session_id}, state) do
    handle_cast({:unregister_sse_handler, session_id, nil}, state)
  end

  @impl GenServer
  def handle_cast({:unregister_sse_handler, session_id, expected_pid}, state) do
    case Map.get(state.sse_handlers, session_id) do
      {pid, _ref, _meta} when is_pid(expected_pid) and pid != expected_pid ->
        {:noreply, state}

      {_pid, ref, _meta} ->
        Process.demonitor(ref, [:flush])
        state = %{state | sse_handlers: Map.delete(state.sse_handlers, session_id)}
        {:noreply, schedule_close_if_open(state, session_id)}

      nil ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast({:close_session_stream, session_id}, state) do
    timers = cancel_close_timer(state.stream_timers, session_id)
    close_stream(%{state | stream_timers: timers}, session_id)
  end

  @impl GenServer
  def handle_cast(:shutdown, state) do
    Logging.transport_event("shutdown", %{transport: :streamable_http}, level: :info)

    for {_session_id, {pid, _ref, _meta}} <- state.sse_handlers do
      send(pid, :close_sse)
    end

    Telemetry.execute(
      Telemetry.event_transport_disconnect(),
      %{system_time: System.system_time()},
      %{transport: :streamable_http, reason: :shutdown}
    )

    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_handler_session(state.sse_handlers, pid, ref) do
      nil ->
        {:noreply, state}

      session_id ->
        Logging.transport_event("sse_handler_down", %{reason: inspect(reason)})
        state = %{state | sse_handlers: Map.delete(state.sse_handlers, session_id)}
        {:noreply, schedule_close_if_open(state, session_id)}
    end
  end

  def handle_info({:close_stream_if_idle, session_id, token}, state) do
    case Map.get(state.stream_timers, session_id) do
      {_ref, ^token} ->
        timers = Map.delete(state.stream_timers, session_id)

        if Map.has_key?(state.sse_handlers, session_id) do
          {:noreply, %{state | stream_timers: timers}}
        else
          close_stream(%{state | stream_timers: timers}, session_id)
        end

      # Stale message: the timer was cancelled/superseded (e.g. the client
      # reconnected and re-disconnected, arming a fresh timer). Ignore it so it
      # cannot close the newly reopened stream.
      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:send_keepalive, state) do
    for {_session_id, {pid, _ref, _meta}} <- state.sse_handlers do
      send(pid, :sse_keepalive)
    end

    if should_keepalive?(state) do
      schedule_keepalive(state.keepalive_interval)
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logging.transport_event("unknown handle_info message", msg, level: :warning)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, _state) do
    Telemetry.execute(
      Telemetry.event_transport_terminate(),
      %{system_time: System.system_time()},
      %{transport: :streamable_http, reason: reason}
    )

    :ok
  end

  # Schedules the next SSE keepalive message.
  #
  # Sends a `:send_keepalive` message to self() after the specified interval.
  # This is used to maintain active SSE connections by preventing idle timeouts.
  #
  # ## Parameters
  #   * `interval` - Time in milliseconds until next keepalive
  defp schedule_keepalive(interval) do
    Process.send_after(self(), :send_keepalive, interval)
  end

  # Determines whether SSE keepalive messages should be sent.
  #
  # Returns `true` if keepalive is enabled and there are active SSE handlers,
  # `false` otherwise. This prevents unnecessary keepalive scheduling when
  # no clients are connected or keepalive is disabled.
  #
  # ## Parameters
  #   * `state` - The GenServer state containing keepalive config and handlers
  defp should_keepalive?(state) do
    state.keepalive_enabled and not Enum.empty?(state.sse_handlers)
  end

  # Resumability helpers. With no event store these are no-ops and the transport
  # keeps its legacy connected-handlers-only broadcast behavior.

  defp open_stream(%{event_store: nil} = state, _session_id), do: state.streams

  defp open_stream(%{event_store: {_mod, _name}} = state, session_id) do
    MapSet.put(state.streams, session_id)
  end

  defp route(%{event_store: nil} = state, session_id, message) do
    case Map.get(state.sse_handlers, session_id) do
      {pid, _ref} ->
        send(pid, {:sse_message, message})
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :no_sse_handler}, state}
    end
  end

  defp route(%{event_store: {_mod, _name} = store} = state, session_id, message) do
    if MapSet.member?(state.streams, session_id) do
      {:reply, record_and_deliver(store, state.sse_handlers, session_id, message), state}
    else
      {:reply, {:error, :no_sse_handler}, state}
    end
  end

  defp broadcast(%{event_store: nil} = state, message) do
    for {_session_id, {pid, _ref}} <- state.sse_handlers do
      send(pid, {:sse_message, message})
    end

    :ok
  end

  # Records into every open stream; returns the first append error (if any) so a
  # dropped write is surfaced to the caller rather than silently swallowed.
  defp broadcast(%{event_store: {_mod, _name} = store} = state, message) do
    Enum.reduce(state.streams, :ok, fn session_id, acc ->
      keep_first_error(acc, record_and_deliver(store, state.sse_handlers, session_id, message))
    end)
  end

  defp keep_first_error({:error, _reason} = first, _result), do: first
  defp keep_first_error(:ok, result), do: result

  # Records the event, then delivers it live (with its store id) only if it was
  # actually recorded. A failed append is logged and NOT delivered with a bogus
  # legacy id, which would corrupt the client's resumption cursor; the error is
  # returned so callers can surface it rather than reporting a phantom success.
  defp record_and_deliver({mod, name}, sse_handlers, session_id, message) do
    case mod.append(name, session_id, message) do
      {:ok, id} ->
        case Map.get(sse_handlers, session_id) do
          {pid, _ref} -> send(pid, {:sse_message, message, id})
          nil -> :ok
        end

        :ok

      {:error, reason} = error ->
        Logging.transport_event("sse_record_failed", %{session_id: session_id, reason: inspect(reason)}, level: :warning)
        error
    end
  end

  # Schedules a bounded grace timer to close a session's stream once its handler
  # has been absent for `:stream_grace`. Cancelled on reconnect. This keeps
  # recording across short reconnect gaps while bounding memory for sessions that
  # drop and never return (which would otherwise leak and thrash the store's LRU).
  defp schedule_close_if_open(%{event_store: nil} = state, _session_id), do: state

  defp schedule_close_if_open(state, session_id) do
    if MapSet.member?(state.streams, session_id) do
      timers = cancel_close_timer(state.stream_timers, session_id)
      token = make_ref()
      ref = Process.send_after(self(), {:close_stream_if_idle, session_id, token}, state.stream_grace)
      %{state | stream_timers: Map.put(timers, session_id, {ref, token})}
    else
      state
    end
  end

  defp cancel_close_timer(timers, session_id) do
    case Map.pop(timers, session_id) do
      {nil, timers} ->
        timers

      {{ref, _token}, timers} ->
        Process.cancel_timer(ref)
        timers
    end
  end

  defp close_stream(%{event_store: nil} = state, _session_id), do: {:noreply, state}

  defp close_stream(%{event_store: {mod, name}} = state, session_id) do
    log_delete_result(mod.delete(name, session_id), session_id)
    {:noreply, %{state | streams: MapSet.delete(state.streams, session_id)}}
  end

  defp log_delete_result(:ok, _session_id), do: :ok

  defp log_delete_result({:error, reason}, session_id) do
    Logging.transport_event("sse_delete_failed", %{session_id: session_id, reason: inspect(reason)}, level: :warning)
  end

  defp find_handler_session(sse_handlers, pid, ref) do
    Enum.find_value(sse_handlers, fn {session_id, {handler_pid, monitor_ref}} ->
      if handler_pid == pid and monitor_ref == ref, do: session_id
    end)
  end
end
