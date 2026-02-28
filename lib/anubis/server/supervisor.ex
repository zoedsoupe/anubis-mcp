defmodule Anubis.Server.Supervisor do
  @moduledoc false

  use Supervisor, restart: :permanent
  use Anubis.Logging

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
          | {:session_idle_timeout, pos_integer() | nil}
          | {:request_timeout, pos_integer() | nil}
          | {:server_name, GenServer.name() | nil}

  @doc """
  Starts the server supervisor.

  ## Parameters

    * `server` - The module implementing `Anubis.Server`
    * `opts` - Options including:
      * `:transport` - Transport configuration (required)
      * `:name` - Supervisor name (optional, defaults to registered name)
      * `:registry` - The custom registry to use to manage processes names (defaults to `Anubis.Server.Registry`)
      * `:session_idle_timeout` - Time in milliseconds before idle sessions expire (default: 30 minutes)
      * `:request_timeout` - Time limit in miliseconds for server requests timeout (defaults to 30s)
      * `:server_name` - Custom server name, non derived from the `server_module`

  ## Examples

      # Start with STDIO transport
      Anubis.Server.Supervisor.start_link(MyServer, [], transport: :stdio)

      # Start with StreamableHTTP transport
      Anubis.Server.Supervisor.start_link(MyServer, [],
        transport: {:streamable_http, port: 8080}
      )

      # With custom session timeout (15 minutes)
      Anubis.Server.Supervisor.start_link(MyServer, [],
        transport: {:streamable_http, port: 8080},
        session_idle_timeout: :timer.minutes(15)
      )
  """
  @spec start_link(server :: module, list(start_option)) :: Supervisor.on_start()
  def start_link(server, opts) when is_atom(server) and is_list(opts) do
    registry = Keyword.get(opts, :registry, Anubis.Server.Registry)
    name = Keyword.get(opts, :name, registry.supervisor(server))
    opts = Keyword.merge(opts, module: server, registry: registry)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts a new session under the DynamicSupervisor.

  Called by transport layer when a new client connects.
  """
  @spec start_session(module(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(registry \\ Anubis.Server.Registry, server, opts) do
    sup_name = registry.supervisor(:session_supervisor, server)
    DynamicSupervisor.start_child(sup_name, {Session, opts})
  end

  @doc """
  Terminates a session.
  """
  @spec stop_session(module(), module(), String.t()) :: :ok | {:error, :not_found}
  def stop_session(registry \\ Anubis.Server.Registry, server, session_id) do
    if pid = registry.whereis_server_session(server, session_id) do
      sup_name = registry.supervisor(:session_supervisor, server)
      DynamicSupervisor.terminate_child(sup_name, pid)
    else
      {:error, :not_found}
    end
  end

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :module)
    transport = normalize_transport(Keyword.fetch!(opts, :transport))
    registry = Keyword.fetch!(opts, :registry)

    if should_start?(transport) do
      {layer, transport_opts} = parse_transport_child(transport, server, registry)

      session_idle_timeout = Keyword.get(opts, :session_idle_timeout)
      request_timeout = Keyword.get(opts, :request_timeout, to_timeout(second: 30))
      task_supervisor = registry.task_supervisor(server)
      transport_name = transport_opts[:name]

      # Session configuration shared across all sessions
      # Stored as a persistent term or passed through DynamicSupervisor
      session_config = %{
        server_module: server,
        registry: registry,
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
            build_stdio_children(server, registry, layer, transport_opts, task_supervisor, session_config)

          _ ->
            build_http_children(server, registry, layer, transport_opts, task_supervisor)
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

  # For STDIO: single session, no DynamicSupervisor needed
  defp build_stdio_children(server, registry, layer, transport_opts, task_supervisor, session_config) do
    session_name = registry.server_session(server, "stdio")

    session_opts = [
      session_id: "stdio",
      server_module: server,
      name: session_name,
      transport: session_config.transport,
      registry: registry,
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

  # For HTTP transports: DynamicSupervisor for sessions
  defp build_http_children(server, registry, layer, transport_opts, task_supervisor) do
    session_sup_name = registry.supervisor(:session_supervisor, server)

    [
      {Task.Supervisor, name: task_supervisor},
      {DynamicSupervisor, name: session_sup_name, strategy: :one_for_one},
      {layer, transport_opts}
    ]
  end

  defp normalize_transport(t) when t in [:stdio, StubTransport], do: t
  defp normalize_transport(t) when t in ~w(sse streamable_http)a, do: {t, []}

  defp normalize_transport({t, opts}) when t in ~w(sse streamable_http)a, do: {t, opts}

  if Mix.env() == :test do
    defp parse_transport_child(StubTransport = kind, server, registry) do
      name = registry.transport(server, kind)
      opts = [name: name, server: server, registry: registry]
      {kind, opts}
    end
  end

  defp parse_transport_child(:stdio, server, registry) do
    name = registry.transport(server, :stdio)
    opts = [name: name, server: server, registry: registry]
    {STDIO, opts}
  end

  defp parse_transport_child({:streamable_http, opts}, server, registry) do
    name = registry.transport(server, :streamable_http)
    opts = Keyword.merge(opts, name: name, server: server, registry: registry)
    {StreamableHTTP, opts}
  end

  defp parse_transport_child({:sse, opts}, server, registry) do
    Logging.log(
      :warning,
      "The :sse transport option is deprecated as of MCP specification 2025-03-26. " <>
        "Please use {:streamable_http, opts} instead. " <>
        "The SSE transport is maintained only for backward compatibility with MCP protocol version 2024-11-05.",
      []
    )

    name = registry.transport(server, :sse)
    opts = Keyword.merge(opts, name: name, server: server, registry: registry)
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
