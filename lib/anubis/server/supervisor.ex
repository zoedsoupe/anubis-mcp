defmodule Anubis.Server.Supervisor do
  @moduledoc false

  use Supervisor, restart: :permanent
  use Anubis.Logging

  alias Anubis.Server.Authorization
  alias Anubis.Server.Registry
  alias Anubis.Server.Session
  alias Anubis.Server.TaskStore
  alias Anubis.Server.Transport.SSE
  alias Anubis.Server.Transport.STDIO
  alias Anubis.Server.Transport.StreamableHTTP
  alias Anubis.Server.Transport.StreamableHTTP.EventStore

  @default_event_store Anubis.Server.Transport.StreamableHTTP.EventStore.InMemory

  @type sse :: {:sse, keyword()}
  @type stream_http :: {:streamable_http, keyword()}

  @type transport :: :stdio | stream_http | sse | StubTransport

  @type start_option ::
          {:transport, transport}
          | {:name, Supervisor.name()}
          | {:registry, {module(), keyword()}}
          | {:supervisor, {module(), keyword()}}
          | {:task_store, {module(), keyword()}}
          | {:session_idle_timeout, pos_integer() | nil}
          | {:request_timeout, pos_integer() | nil}
          | {:authorization, keyword() | nil}

  @doc """
  Starts the server supervisor.

  ## Parameters

    * `server` - The module implementing `Anubis.Server`
    * `opts` - Options including:
      * `:transport` - Transport configuration (required)
      * `:name` - Supervisor name (optional, defaults to atom name)
      * `:registry` - `{module, opts}` for custom registry (auto-selected by default)
      * `:supervisor` - `{module, opts}` for custom session supervisor (defaults to `{DynamicSupervisor, []}`)
      * `:session_idle_timeout` - Time in milliseconds before idle sessions expire (default: 30 minutes)
      * `:request_timeout` - Time limit in milliseconds for server requests (defaults to 30s)
  """
  @spec start_link(server :: module, list(start_option)) :: Supervisor.on_start()
  def start_link(server, opts) when is_atom(server) and is_list(opts) do
    name = Keyword.get(opts, :name, Registry.supervisor_name(server))
    opts = Keyword.put(opts, :module, server)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts a new session under the configured session supervisor.
  """
  @spec start_session(module(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(server, opts) do
    sup_name = Registry.session_supervisor_name(server)
    sup_mod = get_session_supervisor_mod(server)
    sup_mod.start_child(sup_name, {Session, opts})
  end

  @doc """
  Terminates a session.
  """
  @spec stop_session(module(), module(), String.t()) :: :ok | {:error, :not_found}
  def stop_session(server, registry_mod, session_id) do
    registry_name = Registry.registry_name(server)

    case registry_mod.lookup_session(registry_name, session_id) do
      {:ok, pid} ->
        sup_name = Registry.session_supervisor_name(server)
        sup_mod = get_session_supervisor_mod(server)
        sup_mod.terminate_child(sup_name, pid)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :module)
    transport = normalize_transport(Keyword.fetch!(opts, :transport))

    maybe_store_authorization_config(server, transport, opts)

    if should_start?(transport) do
      session_idle_timeout = Keyword.get(opts, :session_idle_timeout)
      request_timeout = Keyword.get(opts, :request_timeout, to_timeout(second: 30))
      task_supervisor = Registry.task_supervisor_name(server)

      {registry_mod, registry_opts} = resolve_registry(opts, transport, server)
      {sup_mod, _sup_opts} = resolve_session_supervisor(opts)
      {task_store_mod, task_store_opts} = resolve_task_store(opts, server)

      :persistent_term.put({__MODULE__, server, :session_supervisor_mod}, sup_mod)

      {layer, transport_opts} = parse_transport_child(transport, server)

      transport_name = transport_opts[:name]

      task_store_name = TaskStore.resolve_name(task_store_mod, server, task_store_opts)

      session_config = %{
        server_module: server,
        registry_mod: registry_mod,
        transport: [layer: layer, name: transport_name],
        session_idle_timeout: session_idle_timeout,
        timeout: request_timeout,
        task_supervisor: task_supervisor,
        task_store: [adapter: task_store_mod, name: task_store_name]
      }

      :persistent_term.put({__MODULE__, server, :session_config}, session_config)

      {event_store_spec, sse_retry} = resolve_event_store(transport, server)

      transport_opts =
        Keyword.merge(transport_opts,
          request_timeout: request_timeout,
          task_supervisor: task_supervisor,
          event_store: event_store_reference(event_store_spec),
          sse_retry: sse_retry
        )

      task_store_child = task_store_child_spec(task_store_mod, task_store_opts, task_store_name)
      event_store_child = event_store_child_spec(event_store_spec)

      children =
        case transport do
          :stdio ->
            build_stdio_children(
              server,
              layer,
              transport_opts,
              task_supervisor,
              session_config,
              task_store_child
            )

          _ ->
            store_children = Enum.reject([event_store_child, task_store_child], &is_nil/1)

            build_http_children(
              server,
              registry_mod,
              registry_opts,
              sup_mod,
              layer,
              transport_opts,
              task_supervisor,
              store_children
            )
        end

      Supervisor.init(children, strategy: :one_for_all)
    else
      :ignore
    end
  end

  @doc false
  def get_session_config(server) do
    :persistent_term.get({__MODULE__, server, :session_config})
  end

  @doc false
  def get_session_supervisor_mod(server) do
    :persistent_term.get({__MODULE__, server, :session_supervisor_mod}, DynamicSupervisor)
  end

  @doc """
  Returns the parsed authorization config for the given server module, or `nil`
  if no authorization is configured.
  """
  @spec get_authorization_config(module()) :: map() | nil
  def get_authorization_config(server) do
    :persistent_term.get({__MODULE__, server, :authorization_config}, nil)
  end

  defp maybe_store_authorization_config(server, transport, opts) do
    case Keyword.get(opts, :authorization) do
      nil ->
        :persistent_term.erase({__MODULE__, server, :authorization_config})
        :ok

      auth_opts when is_list(auth_opts) ->
        case transport do
          :stdio ->
            :persistent_term.erase({__MODULE__, server, :authorization_config})

            Logging.log(
              :warning,
              "Authorization config is ignored for STDIO transport on server #{inspect(server)}",
              []
            )

          _ ->
            parsed = Authorization.parse_config!(auth_opts)
            :persistent_term.put({__MODULE__, server, :authorization_config}, parsed)
        end
    end
  end

  defp resolve_session_supervisor(opts) do
    case Keyword.get(opts, :supervisor) do
      {mod, sup_opts} -> {mod, sup_opts}
      nil -> {DynamicSupervisor, []}
    end
  end

  defp resolve_task_store(opts, _server) do
    case Keyword.get(opts, :task_store) do
      {mod, store_opts} when is_atom(mod) -> {mod, store_opts}
      nil -> {Anubis.Server.TaskStore.Local, []}
    end
  end

  defp task_store_child_spec(adapter, store_opts, store_name) do
    case adapter.child_spec(Keyword.put_new(store_opts, :name, store_name)) do
      :ignore -> nil
      spec -> spec
    end
  end

  # Resolves the optional SSE event store for resumability. Only the
  # streamable_http transport carries a standalone stream, so other transports
  # never get a store. Returns `{spec, retry}` where `spec` is `{module, opts,
  # name}` or `nil`, and `retry` is the configured SSE `retry:` value.
  defp resolve_event_store({:streamable_http, opts}, server) do
    spec = event_store_spec(Keyword.get(opts, :event_store, false), opts, server)
    retry = Keyword.get(opts, :sse_retry)

    if is_nil(spec) and not is_nil(retry) do
      Logging.log(
        :warning,
        "streamable_http :sse_retry is set but resumability (:event_store) is disabled; the retry field will not be emitted",
        []
      )
    end

    {spec, retry}
  end

  defp resolve_event_store(_transport, _server), do: {nil, nil}

  defp event_store_spec(disabled, _opts, _server) when disabled in [false, nil], do: nil

  defp event_store_spec(true, opts, server) do
    event_store_spec({@default_event_store, default_event_store_opts(opts)}, opts, server)
  end

  defp event_store_spec({mod, store_opts}, _opts, server) when is_atom(mod) and is_list(store_opts) do
    {mod, store_opts, EventStore.resolve_name(mod, server, store_opts)}
  end

  defp event_store_spec(mod, opts, server) when is_atom(mod) do
    event_store_spec({mod, []}, opts, server)
  end

  defp event_store_spec(other, _opts, _server) do
    raise ArgumentError,
          "invalid :event_store #{inspect(other)} for the streamable_http transport; " <>
            "expected false | nil | true | module | {module, keyword}"
  end

  # Surfaces the in-memory store's bounds through the transport opts, dropping
  # any the host did not set so the adapter's own defaults apply.
  defp default_event_store_opts(opts) do
    Enum.reject(
      [history_size: Keyword.get(opts, :event_store_history), max_sessions: Keyword.get(opts, :event_store_max_sessions)],
      fn {_key, value} -> is_nil(value) end
    )
  end

  defp event_store_reference(nil), do: nil
  defp event_store_reference({mod, _opts, name}), do: {mod, name}

  defp event_store_child_spec(nil), do: nil

  defp event_store_child_spec({mod, store_opts, name}) do
    case mod.child_spec(Keyword.put_new(store_opts, :name, name)) do
      :ignore -> nil
      spec -> spec
    end
  end

  # Auto-select registry: STDIO -> None, HTTP -> Local
  defp resolve_registry(opts, transport, server) do
    name = Registry.registry_name(server)

    case Keyword.get(opts, :registry) do
      {mod, registry_opts} ->
        {mod, Keyword.put_new(registry_opts, :name, name)}

      nil ->
        case transport do
          :stdio ->
            {Registry.None, []}

          _ ->
            {Registry.Local, [name: name]}
        end
    end
  end

  # For STDIO: single session, no DynamicSupervisor, no registry
  defp build_stdio_children(server, layer, transport_opts, task_supervisor, session_config, task_store_child) do
    session_name = Registry.stdio_session_name(server)

    session_opts = [
      session_id: "stdio",
      server_module: server,
      name: session_name,
      transport: session_config.transport,
      session_idle_timeout: session_config.session_idle_timeout || to_timeout(minute: 30),
      timeout: session_config.timeout,
      task_supervisor: task_supervisor,
      task_store: session_config.task_store
    ]

    base = [
      {Task.Supervisor, name: task_supervisor},
      {Session, session_opts},
      {layer, transport_opts}
    ]

    if task_store_child, do: [task_store_child | base], else: base
  end

  # For HTTP transports: session supervisor (DynamicSupervisor or pluggable) +
  # registry. `store_children` are the already-resolved task/event store child
  # specs, started before the transport under `:one_for_all`.
  defp build_http_children(
         server,
         registry_mod,
         registry_opts,
         sup_mod,
         layer,
         transport_opts,
         task_supervisor,
         store_children
       ) do
    session_sup_name = Registry.session_supervisor_name(server)

    registry_child =
      case registry_mod.child_spec(registry_opts) do
        :ignore -> nil
        spec -> spec
      end

    base = [
      {Task.Supervisor, name: task_supervisor},
      {sup_mod, name: session_sup_name, strategy: :one_for_one},
      {layer, transport_opts}
    ]

    base = if registry_child, do: [registry_child | base], else: base
    store_children ++ base
  end

  defp normalize_transport(t) when t in [:stdio, StubTransport], do: t
  defp normalize_transport(t) when t in ~w(sse streamable_http)a, do: {t, []}

  defp normalize_transport({t, opts}) when t in ~w(sse streamable_http)a, do: {t, opts}

  if Mix.env() == :test do
    defp parse_transport_child(StubTransport = kind, server) do
      name = Registry.transport_name(server, kind)
      opts = [name: name, server: server]
      {kind, opts}
    end
  end

  defp parse_transport_child(:stdio, server) do
    name = Registry.transport_name(server, :stdio)
    opts = [name: name, server: server]
    {STDIO, opts}
  end

  defp parse_transport_child({:streamable_http, opts}, server) do
    name = Registry.transport_name(server, :streamable_http)
    opts = Keyword.merge(opts, name: name, server: server)
    {StreamableHTTP, opts}
  end

  defp parse_transport_child({:sse, opts}, server) do
    Logging.log(
      :warning,
      "The :sse transport option is deprecated as of MCP specification 2025-03-26. " <>
        "Please use {:streamable_http, opts} instead. " <>
        "The SSE transport is maintained only for backward compatibility with MCP protocol version 2024-11-05.",
      []
    )

    name = Registry.transport_name(server, :sse)
    opts = Keyword.merge(opts, name: name, server: server)
    {SSE, opts}
  end

  if Mix.env() == :test do
    defp should_start?(StubTransport), do: true
  end

  defp should_start?(:stdio), do: true

  defp should_start?({transport, opts}) when transport in ~w(sse streamable_http)a do
    start? = Keyword.get(opts, :start)
    if is_nil(start?), do: http_server_running?(), else: start?
  end

  defp http_server_running? do
    cond do
      System.get_env("ANUBIS_MCP_SERVER") -> true
      System.get_env("PHX_SERVER") -> true
      true -> check_phoenix_config()
    end
  end

  defp check_phoenix_config do
    phoenix_start? = Application.get_env(:phoenix, :serve_endpoints)

    if is_nil(phoenix_start?), do: true, else: phoenix_start?
  end
end
