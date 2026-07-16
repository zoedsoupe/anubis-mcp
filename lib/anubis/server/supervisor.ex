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
          | {:finch_name, Finch.name()}

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
    finch_name = Keyword.get(opts, :finch_name, Anubis.Finch)

    maybe_store_authorization_config(server, transport, opts, finch_name)

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

      transport_opts =
        Keyword.merge(transport_opts,
          request_timeout: request_timeout,
          task_supervisor: task_supervisor
        )

      task_store_child = task_store_child_spec(task_store_mod, task_store_opts, task_store_name)

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
            extra_children =
              List.wrap(maybe_finch_child(opts, finch_name)) ++
                session_store_children(Application.get_env(:anubis_mcp, :session_store, []))

            build_http_children(
              server,
              registry_mod,
              registry_opts,
              sup_mod,
              layer,
              transport_opts,
              task_supervisor,
              task_store_child,
              extra_children
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

  defp maybe_store_authorization_config(server, transport, opts, finch_name) do
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
            parsed = auth_opts |> Authorization.parse_config!() |> Map.put(:finch_name, finch_name)
            :persistent_term.put({__MODULE__, server, :authorization_config}, parsed)
        end
    end
  end

  # Only start a default Finch when authorization needs one and the caller
  # didn't bring its own pool. Pass :finch_name to run/size/share your own.
  defp maybe_finch_child(opts, finch_name) do
    auth_configured? = not is_nil(Keyword.get(opts, :authorization))
    brings_own_finch? = Keyword.has_key?(opts, :finch_name)

    if auth_configured? and not brings_own_finch? do
      # ponytail: default size 15; bring your own :finch_name to size/share it
      {Finch, name: finch_name, pools: %{default: [size: 15]}}
    end
  end

  # ponytail: single global session store; running multiple servers means
  # starting the store yourself and leaving :session_store disabled here.
  @doc false
  def session_store_children(config) when is_list(config) do
    enabled? = Keyword.get(config, :enabled, false)
    adapter = Keyword.get(config, :adapter)

    cond do
      not enabled? ->
        []

      is_nil(adapter) ->
        Logging.log(:warning, "Session store enabled but adapter not configured", [])
        []

      Code.ensure_loaded?(adapter) ->
        Logging.log(:info, "Starting session store",
          enabled: true,
          adapter: adapter,
          ttl: Keyword.get(config, :ttl),
          namespace: Keyword.get(config, :namespace)
        )

        [{adapter, config}]

      true ->
        Logging.log(:warning, "Session store enabled but adapter not available", adapter: adapter)
        []
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

  # For HTTP transports: session supervisor (DynamicSupervisor or pluggable) + registry
  defp build_http_children(
         server,
         registry_mod,
         registry_opts,
         sup_mod,
         layer,
         transport_opts,
         task_supervisor,
         task_store_child,
         extra_children
       ) do
    session_sup_name = Registry.session_supervisor_name(server)
    naming_registry = Registry.naming_registry_name(Registry.registry_name(server))

    registry_child =
      case registry_mod.child_spec(registry_opts) do
        :ignore -> nil
        spec -> spec
      end

    base =
      extra_children ++
        [
          {Task.Supervisor, name: task_supervisor},
          {Elixir.Registry, keys: :unique, name: naming_registry},
          {sup_mod, name: session_sup_name, strategy: :one_for_one},
          {layer, transport_opts}
        ]

    base = if registry_child, do: [registry_child | base], else: base
    if task_store_child, do: [task_store_child | base], else: base
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
