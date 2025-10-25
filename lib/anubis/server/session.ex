defmodule Anubis.Server.Session do
  @moduledoc false

  use Agent, restart: :transient

  require Logger

  @type t :: %__MODULE__{
          protocol_version: String.t() | nil,
          initialized: boolean(),
          name: GenServer.name() | nil,
          client_info: map() | nil,
          client_capabilities: map() | nil,
          log_level: String.t(),
          id: String.t() | nil,
          pending_requests: %{
            String.t() => %{started_at: integer(), method: String.t()}
          }
        }

  defstruct [
    :id,
    :protocol_version,
    :log_level,
    :name,
    initialized: false,
    client_info: nil,
    client_capabilities: nil,
    pending_requests: %{}
  ]

  @doc """
  Starts a new session agent with initial state.

  If a session store is configured and the session exists in storage,
  it will be restored. Otherwise, a new session is created.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    name = Keyword.fetch!(opts, :name)
    server_module = Keyword.get(opts, :server_module)

    initial_state =
      case maybe_restore_session(session_id, name, server_module) do
        {:ok, state} ->
          Logger.info("Restored session #{session_id} from store")
          state

        {:error, _reason} ->
          new(id: session_id, name: name)
      end

    Agent.start_link(fn -> initial_state end, name: name)
  end

  @doc """
  Creates a new server state with the given options.
  """
  @spec new(Enumerable.t()) :: t()
  def new(opts), do: struct(__MODULE__, opts)

  @doc """
  Guard to check if a session has been initialized.
  """
  defguard is_initialized(session) when session.initialized

  @doc """
  Retrieves the current state of a session.
  """
  @spec get(GenServer.name()) :: t
  def get(session) do
    Agent.get(session, & &1)
  end

  @doc """
  Updates state after successful initialization handshake.

  This function:
  1. Sets the negotiated protocol version
  2. Stores client information and capabilities
  3. Marks the server as initialized
  4. Persists the session if a store is configured
  """
  @spec update_from_initialization(GenServer.name(), String.t(), map, map) :: :ok
  def update_from_initialization(session, negotiated_version, client_info, capabilities) do
    Agent.update(session, fn state ->
      new_state = %{
        state
        | protocol_version: negotiated_version,
          client_info: client_info,
          client_capabilities: capabilities
      }

      maybe_persist_session(new_state)
      new_state
    end)
  end

  @doc """
  Marks the session as initialized.
  """
  @spec mark_initialized(GenServer.name()) :: :ok
  def mark_initialized(session) do
    Agent.update(session, fn state ->
      new_state = %{state | initialized: true}
      maybe_persist_session(new_state)
      new_state
    end)
  end

  @doc """
  Updates the log level.
  """
  @spec set_log_level(GenServer.name(), String.t()) :: :ok
  def set_log_level(session, level) do
    Agent.update(session, fn state -> %{state | log_level: level} end)
  end

  @doc """
  Tracks a new pending request in the session.
  """
  @spec track_request(GenServer.name(), String.t(), String.t()) :: :ok
  def track_request(session, request_id, method) do
    Agent.update(session, fn state ->
      request_info = %{
        started_at: System.system_time(:millisecond),
        method: method
      }

      %{
        state
        | pending_requests: Map.put(state.pending_requests, request_id, request_info)
      }
    end)
  end

  @doc """
  Removes a completed request from tracking.
  """
  @spec complete_request(GenServer.name(), String.t()) :: map() | nil
  def complete_request(session, request_id) do
    Agent.get_and_update(session, fn state ->
      {request_info, pending_requests} = Map.pop(state.pending_requests, request_id)
      {request_info, %{state | pending_requests: pending_requests}}
    end)
  end

  @doc """
  Checks if a request is currently pending.
  """
  @spec has_pending_request?(GenServer.name(), String.t()) :: boolean()
  def has_pending_request?(session, request_id) do
    Agent.get(session, fn state ->
      Map.has_key?(state.pending_requests, request_id)
    end)
  end

  @doc """
  Gets all pending requests for a session.
  """
  @spec get_pending_requests(GenServer.name()) :: map()
  def get_pending_requests(session) do
    Agent.get(session, & &1.pending_requests)
  end

  # Private persistence functions

  defp maybe_restore_session(session_id, name, server_module) do
    case get_store() do
      nil ->
        Logger.debug("No session store configured, creating new session #{session_id}")
        {:error, :no_store}

      store ->
        Logger.debug("Attempting to restore session #{session_id} from store")

        case store.load(session_id, server: server_module) do
          {:ok, state_map} ->
            Logger.debug("Successfully loaded session #{session_id} from store", %{
              initialized: Map.get(state_map, :initialized, false),
              protocol_version: Map.get(state_map, :protocol_version)
            })

            # Restore the session struct from the persisted map
            state = struct(__MODULE__, state_map)
            # Update the name field to match the current process
            {:ok, %{state | name: name}}

          {:error, :not_found} = error ->
            Logger.debug("Session #{session_id} not found in store, will create new session")
            error

          error ->
            Logger.debug("Failed to load session #{session_id} from store: #{inspect(error)}")
            error
        end
    end
  end

  defp maybe_persist_session(%__MODULE__{} = state) do
    case get_store() do
      nil ->
        Logger.debug("No store configured, skipping persistence for session #{state.id}")
        :ok

      store ->
        Logger.debug("Persisting session #{state.id} to store")
        # Convert struct to map and remove runtime fields
        state_map =
          state
          |> Map.from_struct()
          # Don't persist process names
          |> Map.delete(:name)

        case store.save(state.id, state_map, []) do
          :ok ->
            Logger.debug("Successfully persisted session #{state.id}")
            :ok

          {:error, reason} ->
            Logger.warning("Failed to persist session #{state.id}: #{inspect(reason)}")
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
            Logger.debug("Using session store adapter: #{inspect(adapter)}")
            adapter
          else
            Logger.warning("Session store enabled but adapter not available: #{inspect(adapter)}")
            nil
          end
        else
          Logger.debug("Session store configured but not enabled")
          nil
        end
    end
  end
end

defimpl Inspect, for: Anubis.Server.Session do
  import Inspect.Algebra

  def inspect(session, opts) do
    info = [
      id: session.id,
      initialized: session.initialized,
      pending_requests: map_size(session.pending_requests)
    ]

    info = if session.protocol_version, do: [{:protocol_version, session.protocol_version} | info], else: info
    info = if session.client_info, do: [{:client_info, session.client_info["name"] || "unknown"} | info], else: info

    concat(["#Session<", to_doc(info, opts), ">"])
  end
end
