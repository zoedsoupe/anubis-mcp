if Code.ensure_loaded?(Redix) do
  defmodule Anubis.Server.Session.Store.Redis do
    @moduledoc """
    Redis-based session store implementation.

    Uses Redix for Redis communication and provides persistent session storage
    with automatic expiration and connection pooling.

    ## Configuration

        config :anubis_mcp, :session_store,
          adapter: Anubis.Server.Session.Store.Redis,
          redis_url: "redis://localhost:6379/0",
          pool_size: 10,
          ttl: 1_800_000, # 30 minutes in milliseconds
          namespace: "anubis:sessions",
          connection_name: :anubis_redis,
          redix_opts: []  # Optional Redix connection options

    ## SSL/TLS Configuration

    For Redis servers requiring TLS (like Upstash), pass SSL options via `:redix_opts`:

        config :anubis_mcp, :session_store,
          adapter: Anubis.Server.Session.Store.Redis,
          redis_url: "rediss://default:password@host.upstash.io:6379",
          redix_opts: [
            ssl: true,
            socket_opts: [
              customize_hostname_check: [
                match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
              ]
            ]
          ]

    ## Features

    - Automatic session expiration using Redis TTL
    - Last-write-wins semantics for session updates
    - Connection pooling for high concurrency
    - Namespace support for multi-tenant deployments
    """

    @behaviour Anubis.Server.Session.Store

    use GenServer
    use Anubis.Logging

    alias Anubis.Server.Session.Store

    # 30 minutes in milliseconds
    @default_ttl 1_800_000
    @default_namespace "anubis:sessions"

    defmodule State do
      @moduledoc false
      defstruct [:conn_name, :namespace, :ttl, :pool_size]
    end

    # Client API

    @impl Store
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl Store
    def save(session_id, state, opts \\ []) do
      GenServer.call(__MODULE__, {:save, session_id, state, opts})
    end

    @impl Store
    def load(session_id, opts \\ []) do
      GenServer.call(__MODULE__, {:load, session_id, opts})
    end

    @impl Store
    def delete(session_id, opts \\ []) do
      GenServer.call(__MODULE__, {:delete, session_id, opts})
    end

    @impl Store
    def list_active(opts \\ []) do
      GenServer.call(__MODULE__, {:list_active, opts})
    end

    @impl Store
    def update_ttl(session_id, ttl_ms, opts \\ []) do
      GenServer.call(__MODULE__, {:update_ttl, session_id, ttl_ms, opts})
    end

    @impl Store
    def update(session_id, updates, opts \\ []) do
      GenServer.call(__MODULE__, {:update, session_id, updates, opts})
    end

    @impl Store
    def cleanup_expired(opts \\ []) do
      GenServer.call(__MODULE__, {:cleanup_expired, opts})
    end

    # GenServer callbacks

    @impl GenServer
    def init(opts) do
      redis_url = Keyword.get(opts, :redis_url, "redis://localhost:6379/0")
      conn_name = Keyword.get(opts, :connection_name, :anubis_redis)
      pool_size = Keyword.get(opts, :pool_size, 10)
      namespace = Keyword.get(opts, :namespace, @default_namespace)
      ttl = Keyword.get(opts, :ttl, @default_ttl)
      # Strip :name from custom opts to preserve internal pool naming
      custom_redix_opts =
        opts
        |> Keyword.get(:redix_opts, [])
        |> validate_redix_opts()
        |> Keyword.delete(:name)

      # Start Redix connection pool with anubis_ prefix to avoid conflicts
      children =
        for i <- 1..pool_size do
          child_id = :"anubis_#{conn_name}_#{i}"

          # Default Redix options, merged with custom options (custom takes precedence)
          # Note: :name is always set internally to maintain pool integrity
          redix_opts =
            Keyword.merge([name: child_id, sync_connect: false, exit_on_disconnection: false], custom_redix_opts)

          %{
            id: child_id,
            start: {Redix, :start_link, [redis_url, redix_opts]}
          }
        end

      # Use anubis_ prefix for supervisor name
      supervisor_name = :"anubis_#{conn_name}_supervisor"

      # Start connections under a supervisor
      case Supervisor.start_link(children, strategy: :one_for_one, name: supervisor_name) do
        {:ok, _pid} ->
          state = %State{
            conn_name: conn_name,
            namespace: namespace,
            ttl: ttl,
            pool_size: pool_size
          }

          Logging.log(:info, "Redis session store started successfully",
            namespace: namespace,
            pool_size: pool_size,
            ttl: ttl,
            redis_url: redis_url
          )

          Logging.server_event("redis_store_started", %{
            namespace: namespace,
            pool_size: pool_size,
            ttl: ttl
          })

          {:ok, state}

        {:error, reason} = error ->
          Logging.log(:error, "Failed to start Redis session store", reason: inspect(reason))

          {:stop, error}
      end
    end

    @impl GenServer
    def handle_call({:save, session_id, session_state, opts}, _from, state) do
      ttl = Keyword.get(opts, :ttl, state.ttl)
      key = make_key(state.namespace, session_id)

      case encode_and_save(state, key, session_state, ttl) do
        :ok ->
          Logging.server_event("session_saved", %{session_id: session_id, ttl: ttl})
          {:reply, :ok, state}

        {:error, reason} = error ->
          Logging.log(:error, "Failed to persist session",
            session_id: session_id,
            error: reason
          )

          {:reply, error, state}
      end
    end

    @impl GenServer
    def handle_call({:load, session_id, _opts}, _from, state) do
      key = make_key(state.namespace, session_id)

      case load_and_decode(state, key) do
        {:ok, data} ->
          {:reply, {:ok, data}, state}

        {:error, :not_found} = error ->
          {:reply, error, state}

        {:error, reason} = error ->
          Logging.log(:error, "Failed to load session #{session_id}", error: reason)

          {:reply, error, state}
      end
    end

    @impl GenServer
    def handle_call({:delete, session_id, _opts}, _from, state) do
      key = make_key(state.namespace, session_id)
      conn = get_connection(state)

      case Redix.command(conn, ["DEL", key]) do
        {:ok, _} ->
          Logging.server_event("session_deleted", %{session_id: session_id})
          {:reply, :ok, state}

        {:error, reason} ->
          Logging.log(:error, "Failed to delete session",
            session_id: session_id,
            error: reason
          )

          {:reply, {:error, reason}, state}
      end
    end

    @impl GenServer
    def handle_call({:list_active, opts}, _from, state) do
      pattern = make_key(state.namespace, "*")
      server_filter = Keyword.get(opts, :server)
      conn = get_connection(state)

      case scan_keys(conn, pattern) do
        {:ok, keys} ->
          session_ids =
            keys
            |> Enum.map(&extract_session_id(state.namespace, &1))
            |> filter_by_server(server_filter)

          {:reply, {:ok, session_ids}, state}

        {:error, reason} = error ->
          Logging.log(:error, "Failed to list sessions from store", error: reason)

          {:reply, error, state}
      end
    end

    @impl GenServer
    def handle_call({:update_ttl, session_id, ttl_ms, _opts}, _from, state) do
      key = make_key(state.namespace, session_id)
      conn = get_connection(state)
      ttl_seconds = ms_to_seconds(ttl_ms)

      case Redix.command(conn, ["EXPIRE", key, ttl_seconds]) do
        {:ok, 1} ->
          {:reply, :ok, state}

        {:ok, 0} ->
          {:reply, {:error, :not_found}, state}

        {:error, reason} ->
          Logging.log(:error, "Failed to update TTL for session",
            session_id: session_id,
            error: reason
          )

          {:reply, {:error, reason}, state}
      end
    end

    @impl GenServer
    def handle_call({:update, session_id, updates, opts}, _from, state) do
      key = make_key(state.namespace, session_id)
      ttl = Keyword.get(opts, :ttl, state.ttl)

      case atomic_update(state, key, updates, ttl) do
        :ok ->
          {:reply, :ok, state}

        {:error, :not_found} = error ->
          {:reply, error, state}

        {:error, reason} = error ->
          Logging.log(:error, "Failed to update session",
            session_id: session_id,
            error: reason
          )

          {:reply, error, state}
      end
    end

    @impl GenServer
    def handle_call({:cleanup_expired, _opts}, _from, state) do
      # Redis handles expiration automatically via TTL
      # This is a no-op but we could scan and count expired keys if needed
      {:reply, {:ok, 0}, state}
    end

    # Private functions

    defp validate_redix_opts(nil), do: []

    defp validate_redix_opts(opts) do
      if Keyword.keyword?(opts) do
        opts
      else
        raise ArgumentError, ":redix_opts must be a keyword list"
      end
    end

    defp make_key(namespace, session_id) do
      "#{namespace}:#{session_id}"
    end

    defp extract_session_id(namespace, key) do
      prefix = "#{namespace}:"
      String.replace_prefix(key, prefix, "")
    end

    defp get_connection(state) when is_struct(state, State) do
      # Use cheap monotonic counter for pool selection instead of random
      index = rem(:erlang.unique_integer([:positive]), state.pool_size) + 1
      :"anubis_#{state.conn_name}_#{index}"
    end

    defp json_encode(data) do
      {:ok, JSON.encode!(data)}
    rescue
      error -> {:error, error}
    end

    defp ms_to_seconds(milliseconds) do
      div(milliseconds, 1000)
    end

    defp encode_and_save(state, key, data, ttl) do
      conn = get_connection(state)
      ttl_seconds = ms_to_seconds(ttl)

      case json_encode(data) do
        {:ok, json} ->
          case Redix.command(conn, ["SETEX", key, ttl_seconds, json]) do
            {:ok, "OK"} -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, {:encoding_failed, reason}}
      end
    end

    defp load_and_decode(state, key) do
      conn = get_connection(state)

      case Redix.command(conn, ["GET", key]) do
        {:ok, nil} ->
          {:error, :not_found}

        {:ok, json} ->
          case JSON.decode(json) do
            {:ok, data} -> {:ok, data}
            {:error, reason} -> {:error, {:decoding_failed, reason}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp atomic_update(state, key, updates, ttl) do
      conn = get_connection(state)
      ttl_seconds = ms_to_seconds(ttl)

      # Simple read-modify-write (last-write-wins semantics)
      # Good enough for session storage - sessions are single-writer in practice
      with {:ok, current_data} <- fetch_current_data(conn, key),
           updated_data = Map.merge(current_data, updates),
           {:ok, new_json} <- json_encode(updated_data),
           {:ok, "OK"} <- Redix.command(conn, ["SETEX", key, ttl_seconds, new_json]) do
        :ok
      end
    end

    defp fetch_current_data(conn, key) do
      with {:ok, json} <- fetch_existing_key(conn, key),
           {:ok, data} <- JSON.decode(json) do
        {:ok, data}
      else
        {:error, :not_found} = err -> err
        {:error, reason} -> {:error, {:decoding_failed, reason}}
      end
    end

    defp fetch_existing_key(conn, key) do
      case Redix.command(conn, ["GET", key]) do
        {:ok, nil} -> {:error, :not_found}
        {:ok, json} -> {:ok, json}
        {:error, reason} -> {:error, reason}
      end
    end

    defp scan_keys(conn, pattern, cursor \\ "0", acc \\ []) do
      case Redix.command(conn, ["SCAN", cursor, "MATCH", pattern, "COUNT", "100"]) do
        {:ok, [new_cursor, keys]} ->
          new_acc = acc ++ keys

          if new_cursor == "0" do
            {:ok, new_acc}
          else
            scan_keys(conn, pattern, new_cursor, new_acc)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp filter_by_server(session_ids, nil), do: session_ids

    defp filter_by_server(session_ids, server) do
      # If we need server-specific filtering, we'd need to load each session
      # and check its server field. For now, return all.
      _ = server
      session_ids
    end
  end
end
