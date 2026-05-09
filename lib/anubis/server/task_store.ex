defmodule Anubis.Server.TaskStore do
  @moduledoc """
  Behaviour for pluggable MCP task storage backends.

  A TaskStore tracks `Anubis.Server.Task` entries scoped to a session.
  Adapters are wired via the `:task_store` option of `Anubis.Server.Supervisor`
  using the same `{module, opts}` shape as `:registry` and `:supervisor`:

      {Anubis.Server, transport: :stdio, task_store: {MyApp.HordeTaskStore, []}}

  Phase 1 ships with the in-memory `Anubis.Server.TaskStore.Local` adapter.
  Distributed adapters (e.g. Horde-backed) plug in through this contract
  without API changes.

  ## Naming

  Adapters can either be named processes (default — server boots them under its
  supervision tree using `Anubis.Server.Registry.task_store_name/1`) or expose
  a custom name (`:via` tuple, registered atom in another node, etc.) via the
  optional `resolve_name/2` callback.

  When `resolve_name/2` is implemented and returns a `:via` tuple, the adapter
  is responsible for its own registration — the server supervisor will skip the
  default child spec via `child_spec/1` returning `:ignore`.
  """

  alias Anubis.Server.Task

  @type name :: term()
  @type session_id :: String.t()
  @type task_id :: String.t()

  @callback child_spec(keyword()) :: Supervisor.child_spec() | :ignore
  @callback put(name(), session_id(), Task.t()) :: :ok | {:error, term()}
  @callback get(name(), session_id(), task_id()) :: {:ok, Task.t()} | {:error, :not_found}
  @callback update(name(), session_id(), task_id(), (Task.t() -> Task.t())) ::
              {:ok, Task.t()} | {:error, :not_found}
  @callback delete(name(), session_id(), task_id()) :: :ok
  @callback list_by_session(name(), session_id()) :: [Task.t()]

  @doc """
  Optional. Returns the name used to address the store for a given server.

  Defaults to `Anubis.Server.Registry.task_store_name(server)` when not
  implemented. Override to return a `:via` tuple for distributed adapters.
  """
  @callback resolve_name(server :: module(), opts :: keyword()) :: name()

  @optional_callbacks resolve_name: 2

  @doc """
  Resolves the configured task store name for a server, asking the adapter if
  it implements `resolve_name/2` and falling back to the default atom naming.

  Uses `Code.ensure_loaded?/1` first because in releases the adapter beam may
  exist on disk but not yet be loaded into the VM, in which case
  `function_exported?/3` silently returns false and we'd skip the override.
  """
  @spec resolve_name(module(), module(), keyword()) :: name()
  def resolve_name(adapter, server, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :resolve_name, 2) do
      adapter.resolve_name(server, opts)
    else
      Anubis.Server.Registry.task_store_name(server)
    end
  end
end
