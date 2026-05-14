defmodule Anubis.Server.Registry.PG do
  @moduledoc """
  Distributed session registry backed by Erlang's `:pg` (process groups) module.

  Uses a named `:pg` scope to track session PIDs across all nodes in an Erlang
  cluster, enabling transparent cross-node request routing for horizontally
  scaled MCP server deployments.

  ## When to use this registry

  The default `Anubis.Server.Registry.Local` stores session PIDs in a node-local
  ETS table. In a multi-node deployment without sticky sessions this causes
  failures:

  1. An `initialize` request hits node A — session process starts there.
  2. The `notifications/initialized` notification hits node B — no local session
     found, 404 returned, notification lost.
  3. A subsequent `tools/call` back to node A finds the live session with
     `initialized: false` → `"Server not initialized"` error.

  `Registry.PG` solves this by tracking session PIDs in a `:pg` scope that is
  shared across all connected Erlang nodes. When node B receives any request for
  a session that lives on node A:

  1. `lookup_session/2` queries `:pg` and returns node A's session PID.
  2. `GenServer.call/3` routes the request to node A transparently via
     distributed Erlang — no serialisation, no HTTP hop.
  3. The session on node A handles the request in its correct state.

  `:pg` monitors registered processes and removes their entries automatically
  when a process exits, so stale PIDs are never returned.

  ## Requirements

  - OTP 23+ (`:pg` was introduced in OTP 23 as a replacement for `:pg2`).
  - All MCP server nodes must be connected via distributed Erlang. If you are
    not already managing node clustering yourself, libraries such as
    [libcluster](https://github.com/bitwalker/libcluster) can handle automatic
    cluster formation for a variety of strategies including Kubernetes DNS,
    Consul, and gossip protocols.

  ## Usage

      children = [
        {MyServer, transport: {:streamable_http, start: true}, registry: {Anubis.Server.Registry.PG, []}}
      ]

  ## Pairing with a session store

  `Registry.PG` routes requests to live session processes across the cluster.
  It does **not** persist sessions across node restarts. To survive node crashes
  or rolling deployments, pair this registry with an
  `Anubis.Server.Session.Store` implementation (e.g. Redis or a database) so
  that sessions can be restored on any node after a restart.
  """

  @behaviour Anubis.Server.Registry

  @doc """
  Returns a child spec that starts the `:pg` scope for this registry.

  The scope is derived deterministically from `opts[:name]`, which Anubis
  injects automatically. Multiple independent servers on the same node each
  get their own isolated scope.
  """
  @impl Anubis.Server.Registry
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    scope = pg_scope(name)

    %{
      id: {__MODULE__, scope},
      start: {:pg, :start_link, [scope]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Registers `pid` under `session_id` in the cluster-wide `:pg` scope.

  Any node in the cluster can subsequently look up this PID via
  `lookup_session/2`. `:pg` monitors the process and removes it automatically
  when it exits.
  """
  @impl Anubis.Server.Registry
  @spec register_session(name :: term(), Anubis.Server.Registry.session_id(), pid()) :: :ok
  def register_session(name, session_id, pid) do
    :pg.join(pg_scope(name), session_id, pid)
    :ok
  end

  @doc """
  Looks up the PID for `session_id` across the entire cluster.

  Returns `{:ok, pid}` if a live session process is registered on any node in
  the cluster, or `{:error, :not_found}` otherwise. When the PID belongs to a
  remote node, subsequent `GenServer.call/3` invocations are transparently
  routed there by the Erlang runtime.
  """
  @impl Anubis.Server.Registry
  @spec lookup_session(name :: term(), Anubis.Server.Registry.session_id()) ::
          {:ok, pid()} | {:error, :not_found}
  def lookup_session(name, session_id) do
    case :pg.get_members(pg_scope(name), session_id) do
      [pid | _rest] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  rescue
    _e in [ArgumentError] -> {:error, :not_found}
  end

  @doc """
  Removes `session_id` from the cluster-wide `:pg` scope.

  Called by Anubis when a session is explicitly stopped. Note that `:pg` also
  removes entries automatically when the session process exits, so this is
  primarily for intentional teardown.
  """
  @impl Anubis.Server.Registry
  @spec unregister_session(name :: term(), Anubis.Server.Registry.session_id()) :: :ok
  def unregister_session(name, session_id) do
    scope = pg_scope(name)

    for pid <- :pg.get_members(scope, session_id) do
      :pg.leave(scope, session_id, pid)
    end

    :ok
  rescue
    _e in [ArgumentError] -> :ok
  end

  # Derive a deterministic `:pg` scope atom from the registry name.
  # The registry name is a compile-time bounded atom, so there is no risk of
  # atom table exhaustion.
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp pg_scope(name), do: :"#{name}.pg"
end
