defmodule Anubis.Server.Registry do
  @moduledoc """
  Behaviour for pluggable session registries and deterministic naming utilities.

  The registry is responsible for mapping session IDs to PIDs. Different transports
  have different needs:

  - STDIO: single session, no registry needed (`Registry.None`)
  - HTTP: multiple sessions, need lookup by session ID (`Registry.Local`)

  ## Naming Utilities

  The module also provides deterministic atom naming for internal processes
  (transports, supervisors, task stores). These are keyed off the server module,
  which is compile-time bounded, so they cannot exhaust the atom table.

  Session processes are different: their ids come from the client-controlled
  `mcp-session-id` header. `resolve_session_name/3` therefore names sessions via
  an Elixir `Registry` keyed by the session-id string (a `:via` tuple) rather
  than minting one atom per session id.
  """

  @type session_id :: String.t()

  @callback child_spec(keyword()) :: Supervisor.child_spec() | :ignore
  @callback register_session(name :: term(), session_id(), pid()) :: :ok | {:error, term()}
  @callback lookup_session(name :: term(), session_id()) :: {:ok, pid()} | {:error, :not_found}
  @callback unregister_session(name :: term(), session_id()) :: :ok

  @doc """
  Returns the GenServer name for a session. Override this to return a `:via` tuple
  (e.g. `{:via, Horde.Registry, {name, session_id}}`) when using a distributed registry
  that auto-registers processes on `start_link`. The default returns a plain atom.

  When a `:via` tuple is returned, `register_session/3` should be a no-op since
  registration happens automatically on process start.
  """
  @callback session_name(registry_name :: term(), session_id()) :: GenServer.name()

  @optional_callbacks session_name: 2

  @doc """
  Resolves the session GenServer name via the registry adapter.

  Falls back to the default `:via` naming if the adapter does not implement the
  optional `session_name/2` callback.
  """
  @spec resolve_session_name(module(), term(), session_id()) :: GenServer.name()
  def resolve_session_name(registry_mod, registry_name, session_id) do
    if function_exported?(registry_mod, :session_name, 2) do
      registry_mod.session_name(registry_name, session_id)
    else
      session_name_from_registry_name(registry_name, session_id)
    end
  end

  @doc """
  Name of the per-server `Registry` used to name session processes.

  Session ids are client-controlled (the `mcp-session-id` header), so naming
  session processes with `:"\#{registry_name}.session.\#{session_id}"` would mint
  a fresh atom per session id. Atoms are never garbage collected, so an attacker
  feeding distinct session ids could exhaust the atom table and crash the VM.

  Instead we route the default naming through an Elixir `Registry` keyed by the
  session-id string. `registry_name` is a compile-time bounded server atom, so
  deriving this name from it is safe.
  """
  @spec naming_registry_name(atom()) :: atom()
  def naming_registry_name(registry_name) when is_atom(registry_name) do
    :"#{registry_name}.names"
  end

  defp session_name_from_registry_name(registry_name, session_id) do
    {:via, Elixir.Registry, {naming_registry_name(registry_name), session_id}}
  end

  # Deterministic atom naming for internal processes

  @spec transport_name(module(), atom()) :: atom()
  def transport_name(server, type), do: :"Anubis.#{server}.transport.#{type}"

  @spec task_supervisor_name(module()) :: atom()
  def task_supervisor_name(server), do: :"Anubis.#{server}.task_supervisor"

  @doc """
  Default atom name for a server's `Anubis.Server.TaskStore` process. Adapters
  may override via the optional `resolve_name/2` callback to return a `:via`
  tuple for distributed deployments.
  """
  @spec task_store_name(module()) :: atom()
  def task_store_name(server), do: :"Anubis.#{server}.task_store"

  @doc """
  Default atom name for a server's Streamable HTTP SSE event store process.
  Adapters may override via the optional `resolve_name/2` callback to return a
  `:via` tuple for distributed deployments.

  ## Examples

      iex> Anubis.Server.Registry.event_store_name(MyApp.Server)
      :"Anubis.Elixir.MyApp.Server.event_store"
  """
  @spec event_store_name(module()) :: atom()
  def event_store_name(server), do: :"Anubis.#{server}.event_store"

  @spec session_supervisor_name(module()) :: atom()
  def session_supervisor_name(server), do: :"Anubis.#{server}.session_supervisor"

  @spec supervisor_name(module()) :: atom()
  def supervisor_name(server), do: :"Anubis.#{server}.supervisor"

  @doc """
  Deterministic atom name for a session process.

  ## Warning

  This mints an atom per `session_id`. Only call it with compile-time bounded or
  otherwise trusted session ids (e.g. in tests). It must **not** be used on the
  request path with client-supplied session ids, since atoms are never garbage
  collected and an attacker could exhaust the atom table. The runtime session
  naming path goes through `resolve_session_name/3`, which returns a `:via`
  `Registry` name keyed by the session-id string instead.
  """
  @spec session_name(module(), String.t()) :: atom()
  def session_name(server, session_id), do: :"Anubis.#{server}.session.#{session_id}"

  @spec stdio_session_name(module()) :: atom()
  def stdio_session_name(server), do: :"Anubis.#{server}.session.stdio"

  @spec registry_name(module()) :: atom()
  def registry_name(server), do: :"Anubis.#{server}.registry"
end
