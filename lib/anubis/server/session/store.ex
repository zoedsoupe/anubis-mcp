defmodule Anubis.Server.Session.Store do
  @moduledoc """
  Behaviour for session persistence adapters.

  This module defines the interface for implementing session storage backends
  that can persist MCP session state across server restarts. Implementations
  can use various storage solutions like Redis, PostgreSQL, ETS, or any other
  persistence mechanism.

  ## Implementing a Store

  To implement a custom session store, create a module that implements all
  the callbacks defined in this behaviour:

      defmodule MyApp.RedisStore do
        @behaviour Anubis.Server.Session.Store

        def start_link(opts) do
          # Initialize connection to storage backend
        end

        def save(session_id, state, opts) do
          # Persist session state
          :ok
        end

        def load(session_id, opts) do
          # Retrieve session state
          {:ok, state}
        end

        # ... implement other callbacks
      end

  ## Using a Store

  Configure the session store in your application config:

      config :anubis, :session_store,
        adapter: MyApp.RedisStore,
        redis_url: "redis://localhost:6379",
        ttl: 1800  # 30 minutes

  ## Session Security

  Stores should implement appropriate security measures:
  - Generate secure session tokens for validation
  - Encrypt sensitive data before storage
  - Validate session ownership on reconnection
  - Implement proper TTL for automatic cleanup
  """

  @type session_id :: String.t()
  @type session_state :: map()
  @type error :: {:error, term()}
  @type opts :: keyword()

  @doc """
  Starts the storage backend.

  This is called during application startup to initialize the storage
  connection and any required resources.

  ## Parameters
    * `opts` - Configuration options for the storage backend

  ## Returns
    * `{:ok, pid}` - Storage backend started successfully
    * `{:error, reason}` - Failed to start storage backend
  """
  @callback start_link(opts) :: GenServer.on_start()

  @doc """
  Saves a session state to the storage backend.

  The implementation should serialize the session state and persist it
  with appropriate TTL settings.

  ## Parameters
    * `session_id` - Unique identifier for the session
    * `state` - The session state map to persist
    * `opts` - Additional options (e.g., TTL, namespace)

  ## Returns
    * `:ok` - Session saved successfully
    * `{:error, reason}` - Failed to save session
  """
  @callback save(session_id, session_state, opts) :: :ok | error

  @doc """
  Loads a session state from the storage backend.

  Retrieves and deserializes a previously saved session state.
  Should handle expired sessions by returning an appropriate error.

  ## Parameters
    * `session_id` - Unique identifier for the session
    * `opts` - Additional options

  ## Returns
    * `{:ok, state}` - Session state retrieved successfully
    * `{:error, :not_found}` - Session does not exist
    * `{:error, :expired}` - Session has expired
    * `{:error, reason}` - Other retrieval error
  """
  @callback load(session_id, opts) :: {:ok, session_state} | error

  @doc """
  Deletes a session from the storage backend.

  Removes all data associated with a session. Should be idempotent,
  returning success even if the session doesn't exist.

  ## Parameters
    * `session_id` - Unique identifier for the session
    * `opts` - Additional options

  ## Returns
    * `:ok` - Session deleted or didn't exist
    * `{:error, reason}` - Failed to delete session
  """
  @callback delete(session_id, opts) :: :ok | error

  @doc """
  Lists all active sessions.

  Returns a list of session IDs that are currently stored and not expired.
  Useful for session recovery on server startup.

  ## Parameters
    * `opts` - Additional options (e.g., filter by server)

  ## Returns
    * `{:ok, [session_id]}` - List of active session IDs
    * `{:error, reason}` - Failed to list sessions
  """
  @callback list_active(opts) :: {:ok, [session_id]} | error

  @doc """
  Updates the TTL for a session.

  Extends or shortens the expiration time for an existing session.
  Useful for keeping active sessions alive.

  ## Parameters
    * `session_id` - Unique identifier for the session
    * `ttl_seconds` - New TTL in seconds
    * `opts` - Additional options

  ## Returns
    * `:ok` - TTL updated successfully
    * `{:error, :not_found}` - Session doesn't exist
    * `{:error, reason}` - Failed to update TTL
  """
  @callback update_ttl(session_id, ttl_seconds :: pos_integer(), opts) :: :ok | error

  @doc """
  Performs atomic update of session state.

  Updates specific fields in the session state without overwriting the entire
  state. Useful for concurrent updates.

  ## Parameters
    * `session_id` - Unique identifier for the session
    * `updates` - Map of fields to update
    * `opts` - Additional options

  ## Returns
    * `:ok` - Session updated successfully
    * `{:error, :not_found}` - Session doesn't exist
    * `{:error, reason}` - Failed to update session
  """
  @callback update(session_id, updates :: map(), opts) :: :ok | error

  @doc """
  Cleans up expired sessions.

  Removes all sessions that have exceeded their TTL. Should be called
  periodically or on-demand.

  ## Parameters
    * `opts` - Additional options

  ## Returns
    * `{:ok, count}` - Number of sessions cleaned up
    * `{:error, reason}` - Failed to cleanup sessions
  """
  @callback cleanup_expired(opts) :: {:ok, non_neg_integer()} | error

  @optional_callbacks start_link: 1, cleanup_expired: 1
end
