defmodule Anubis.Server.Supervisor do
  @moduledoc false

  use Supervisor, restart: :permanent
  use Anubis.Logging

  alias Anubis.Server.Registry
  alias Anubis.Server.Session
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
          | {:session_idle_timeout, pos_integer() | nil}
          | {:request_timeout, pos_integer() | nil}

  @doc """
  Starts the server supervisor.

  ## Parameters

    * `server` - The module implementing `Anubis.Server`
    * `opts` - Options including:
      * `:transport` - Transport configuration (required)
      * `:name` - Supervisor name (optional, defaults to atom name)
      * `:registry` - `{module, opts}` for custom registry (auto-selected by default)
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
  Starts a new session under the DynamicSupervisor.
  """
  @spec start_session(module(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(server, opts) do
    sup_name = Registry.session_supervisor_name(server)
    DynamicSupervisor.start_child(sup_name, {Session, opts})
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
        DynamicSupervisor.terminate_child(sup_name, pid)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :module)
    transport = normalize_transport(Keyword.fetch!(opts, :transport))

    if should_start?(transport) do
      session_idle_timeout = Keyword.get(opts, :session_idle_timeout)
      request_timeout = Keyword.get(opts, :request_timeout, to_timeout(second: 30))
      task_supervisor = Registry.task_supervisor_name(server)

      {registry_mod, registry_opts} = resolve_registry(opts, transport, server)

      {layer, transport_opts} = parse_transport_child(transport, server)

      transport_name = transport_opts[:name]

      session_config = %{
        server_module: server,
        registry_mod: registry_mod,
        transport: [layer: layer, name: transport_name],
        session_idle_timeout: session_idle_timeout,
        timeout: request_timeout,
        task_supervisor: task_supervisor
      }

      :persistent_term.put({__MODULE__, server, :session_config}, session_config)

      transport_opts =
        Keyword.merge(transport_opts,
          request_timeout: request_timeout,
          task_supervisor: task_supervisor
        )

      children =
        case transport do
          :stdio ->
            build_stdio_children(server, layer, transport_opts, task_supervisor, session_config)

          _ ->
            build_http_children(server, registry_mod, registry_opts, layer, transport_opts, task_supervisor)
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

  # Auto-select registry: STDIO -> None, HTTP -> Local
  defp resolve_registry(opts, transport, server) do
    case Keyword.get(opts, :registry) do
      {mod, registry_opts} ->
        {mod, registry_opts}

      nil ->
        case transport do
          :stdio ->
            {Registry.None, []}

          _ ->
            name = Registry.registry_name(server)
            {Registry.Local, [name: name]}
        end
    end
  end

  # For STDIO: single session, no DynamicSupervisor, no registry
  defp build_stdio_children(server, layer, transport_opts, task_supervisor, session_config) do
    session_name = Registry.stdio_session_name(server)

    session_opts = [
      session_id: "stdio",
      server_module: server,
      name: session_name,
      transport: session_config.transport,
      session_idle_timeout: session_config.session_idle_timeout || to_timeout(minute: 30),
      timeout: session_config.timeout,
      task_supervisor: task_supervisor
    ]

    [
      {Task.Supervisor, name: task_supervisor},
      {Session, session_opts},
      {layer, transport_opts}
    ]
  end

  # For HTTP transports: DynamicSupervisor for sessions + registry
  defp build_http_children(server, registry_mod, registry_opts, layer, transport_opts, task_supervisor) do
    session_sup_name = Registry.session_supervisor_name(server)

    registry_child =
      case registry_mod.child_spec(registry_opts) do
        :ignore -> nil
        spec -> spec
      end

    children = [
      {Task.Supervisor, name: task_supervisor},
      {DynamicSupervisor, name: session_sup_name, strategy: :one_for_one},
      {layer, transport_opts}
    ]

    if registry_child do
      [registry_child | children]
    else
      children
    end
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
