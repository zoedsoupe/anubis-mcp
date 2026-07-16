defmodule Anubis.Server.Transport.StreamableHTTP.EventStore do
  @moduledoc """
  Behaviour for pluggable SSE event stores backing Streamable HTTP resumability.

  An event store records the server-to-client messages sent on a session's
  standalone SSE stream (the one opened with `GET`) and assigns each a
  monotonic, session-scoped event id. When a client reconnects and presents a
  `Last-Event-ID` header, the transport asks the store to replay the events
  recorded after that id, satisfying the MCP
  [resumability and redelivery](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#resumability-and-redelivery)
  contract:

  > Servers **MAY** attach an `id` field to their SSE events. If present, the ID
  > **MUST** be globally unique across all streams within that session. [...] The
  > server **MAY** use this header to replay messages that would have been sent
  > after the last event id, *on the stream that was disconnected*.

  Because ids are recorded independently of whether a handler is currently
  attached, messages fired during a reconnect gap are captured and replayed once
  the client comes back, rather than being lost.

  ## Scope

  Resumability covers the **standalone SSE stream** for a session (the long-lived
  `GET` stream used for server-initiated notifications and requests). One such
  stream exists per session, so a session-scoped monotonic id is globally unique
  within the session as the spec requires. Per-request SSE streams opened by a
  `POST` are their own short-lived streams and are not recorded here; the spec
  forbids replaying a different stream's messages.

  ## Wiring

  Adapters are wired via the `:event_store` option of the `:streamable_http`
  transport, using the same `{module, opts}` shape as `:task_store`:

      Anubis.Server.start_link(MyServer, [],
        transport: {:streamable_http, port: 4000, event_store: {MyApp.RedisEventStore, []}}
      )

  Passing `event_store: true` selects the default in-memory adapter,
  `Anubis.Server.Transport.StreamableHTTP.EventStore.InMemory`. Omitting the
  option (or passing `false`) leaves resumability disabled, preserving the
  legacy per-connection id behavior.

  ## Naming

  Adapters are addressed by a process name. By default the server boots the
  adapter under its supervision tree using
  `Anubis.Server.Registry.event_store_name/1`. Adapters that register themselves
  (e.g. a `:via` tuple for a distributed backend) implement the optional
  `resolve_name/2` callback and return `:ignore` from `child_spec/1`.
  """

  @type name :: term()
  @type session_id :: String.t()
  @type event_id :: non_neg_integer()
  @type data :: binary()

  @doc """
  Returns the child spec used to start the store under the server supervision
  tree, or `:ignore` when the adapter manages its own lifecycle.
  """
  @callback child_spec(keyword()) :: Supervisor.child_spec() | :ignore

  @doc """
  Records `data` as the next event on `session_id`'s standalone stream and
  returns the newly assigned monotonic event id.

  Ids are session-scoped and strictly increasing across reconnects. The store,
  not the connection, owns the counter, so a superseding connection continues
  the sequence rather than restarting it.

  ## Example

      iex> InMemory.append(store, "session-a", "event 1")
      {:ok, 1}
      iex> InMemory.append(store, "session-a", "event 2")
      {:ok, 2}
  """
  @callback append(name(), session_id(), data()) :: {:ok, event_id()} | {:error, term()}

  @doc """
  Returns the events recorded after `after_id` for `session_id`, in ascending id
  order, so the transport can replay them before resuming live delivery.

  A store with bounded retention returns only the events it still holds. When
  `after_id` predates the oldest retained event the caller sees a gap (events
  between `after_id` and the oldest retained id are unrecoverable at the
  transport level); durability for longer windows must live above the transport.

  ## Example

      iex> InMemory.replay(store, "session-a", 1)
      {:ok, [{2, "event 2"}, {3, "event 3"}]}
  """
  @callback replay(name(), session_id(), after_id :: event_id()) ::
              {:ok, [{event_id(), data()}]} | {:error, term()}

  @doc """
  Returns the highest event id assigned to `session_id` so far, or `0` when the
  session has no recorded events. Used to stamp the priming event on a fresh
  stream so the client holds a cursor consistent with the live feed.

  ## Example

      iex> InMemory.latest_id(store, "session-a")
      {:ok, 3}
      iex> InMemory.latest_id(store, "unknown-session")
      {:ok, 0}
  """
  @callback latest_id(name(), session_id()) :: {:ok, event_id()} | {:error, term()}

  @doc """
  Drops all recorded events for `session_id`. Called when a session is explicitly
  terminated (`DELETE`) and on the grace-timer close of an abandoned stream.
  Idempotent.

  Returns `{:error, reason}` if the deletion could not be completed — a durable
  adapter can genuinely fail here. On explicit `DELETE` the transport fails
  closed: the error propagates to the HTTP response and the stream stays in
  transport state so the client can retry; on grace-timer closes the failure is
  logged.

  ## Example

      iex> InMemory.delete(store, "session-a")
      :ok
  """
  @callback delete(name(), session_id()) :: :ok | {:error, term()}

  @doc """
  Optional. Returns the name used to address the store for a given server.

  Defaults to `Anubis.Server.Registry.event_store_name(server)` when not
  implemented. Override to return a `:via` tuple for distributed adapters.

  ## Example

      def resolve_name(server, _opts) do
        {:via, Horde.Registry, {MyApp.EventStores, server}}
      end
  """
  @callback resolve_name(server :: module(), opts :: keyword()) :: name()

  @optional_callbacks resolve_name: 2

  @doc """
  Resolves the configured event store name for a server, asking the adapter if
  it implements `resolve_name/2` and falling back to the default atom naming.

  Uses `Code.ensure_loaded?/1` first because in releases the adapter beam may
  exist on disk but not yet be loaded into the VM, in which case
  `function_exported?/3` silently returns false and we'd skip the override.
  """
  @spec resolve_name(module(), module(), keyword()) :: name()
  def resolve_name(adapter, server, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :resolve_name, 2) do
      adapter.resolve_name(server, opts)
    else
      Anubis.Server.Registry.event_store_name(server)
    end
  end
end
