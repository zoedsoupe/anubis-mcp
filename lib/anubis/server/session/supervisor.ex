defmodule Anubis.Server.Session.Supervisor do
  @moduledoc false

  use DynamicSupervisor

  alias Anubis.Server.Session

  @kind :session_supervisor

  @doc """
  Starts the session supervisor.

  ## Parameters
    * `server` - The server module atom

  ## Returns
    * `{:ok, pid}` - Supervisor started successfully
    * `{:error, reason}` - Failed to start supervisor

  ## Examples

      {:ok, _pid} = Session.Supervisor.start_link(MyServer)
  """
  def start_link(opts \\ []) do
    server = Keyword.fetch!(opts, :server)
    registry = Keyword.get(opts, :registry, Anubis.Server.Registry)
    name = registry.supervisor(@kind, server)

    case DynamicSupervisor.start_link(__MODULE__, {server, registry}, name: name) do
      {:ok, _pid} = success ->
        # Restore sessions from store if configured
        restore_sessions(server, registry)
        success

      error ->
        error
    end
  end

  @doc """
  Creates a new session for a client connection.

  ## Parameters
    * `registry` - The registry module to use to retrieve processes names
    * `server` - The server module atom
    * `session_id` - Unique identifier for the session (typically from transport)

  ## Returns
    * `{:ok, pid}` - Session created successfully
    * `{:error, {:already_started, pid}}` - Session already exists
    * `{:error, reason}` - Failed to create session

  ## Examples

      # Create a new session for a client
      {:ok, session_pid} = Session.Supervisor.create_session(MyRegistry, MyServer, "session-123")

      # Attempting to create duplicate session
      {:error, {:already_started, ^session_pid}} = 
        Session.Supervisor.create_session(MyRegistry, MyServer, "session-123")
  """
  def create_session(registry \\ Anubis.Server.Registry, server, session_id) do
    name = registry.supervisor(@kind, server)
    session_name = registry.server_session(server, session_id)

    DynamicSupervisor.start_child(
      name,
      {Session, session_id: session_id, name: session_name, server_module: server}
    )
  end

  @doc """
  Terminates a session and cleans up its resources.

  ## Parameters
    * `registry` - The registry module to use to retrieve processes names
    * `server` - The server module atom
    * `session_id` - The session identifier to terminate

  ## Returns
    * `:ok` - Session terminated successfully
    * `{:error, :not_found}` - Session does not exist

  ## Examples

      # Close an existing session
      :ok = Session.Supervisor.close_session(MyRegistry, MyServer, "session-123")

      # Attempting to close non-existent session
      {:error, :not_found} = Session.Supervisor.close_session(MyRegistry, MyServer, "unknown")
  """
  def close_session(registry \\ Anubis.Server.Registry, server, session_id) when is_binary(session_id) do
    name = registry.supervisor(@kind, server)

    if pid = registry.whereis_server_session(server, session_id) do
      DynamicSupervisor.terminate_child(name, pid)
    else
      {:error, :not_found}
    end
  end

  @impl DynamicSupervisor
  def init({_server, _registry}) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # Private functions

  defp restore_sessions(server, registry) do
    case get_store() do
      nil ->
        require Logger

        Logger.debug("No session store configured, skipping session restoration")
        :ok

      store ->
        require Logger

        Logger.debug("Checking for sessions to restore from store for server #{inspect(server)}")

        case store.list_active(server: server) do
          {:ok, session_ids} ->
            if length(session_ids) > 0 do
              Logger.info("Restoring #{length(session_ids)} sessions for server #{inspect(server)}")

              Enum.each(session_ids, fn session_id ->
                Logger.debug("Creating session process for restored session: #{session_id}")
                create_session(registry, server, session_id)
              end)
            else
              Logger.debug("No sessions found to restore for server #{inspect(server)}")
            end

            :ok

          {:error, reason} ->
            Logger.warning("Failed to restore sessions: #{inspect(reason)}")
            :ok
        end
    end
  end

  defp get_store do
    case Application.get_env(:anubis_mcp, :session_store) do
      nil ->
        nil

      config ->
        # Check if session store is enabled
        if Keyword.get(config, :enabled, false) do
          adapter = Keyword.get(config, :adapter)

          if adapter && Code.ensure_loaded?(adapter) do
            adapter
          else
            require Logger

            Logger.warning("Session store enabled but adapter not available: #{inspect(adapter)}")
            nil
          end
        end
    end
  end
end
