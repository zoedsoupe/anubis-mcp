defmodule Anubis.Server.Registry do
  @moduledoc """
  Behaviour for pluggable session registries and deterministic naming utilities.

  The registry is responsible for mapping session IDs to PIDs. Different transports
  have different needs:

  - STDIO: single session, no registry needed (`Registry.None`)
  - HTTP: multiple sessions, need lookup by session ID (`Registry.Local`)

  ## Naming Utilities

  The module also provides deterministic atom naming for internal processes.
  These are safe because server modules are compile-time bounded.
  """

  @type session_id :: String.t()

  @callback child_spec(keyword()) :: Supervisor.child_spec() | :ignore
  @callback register_session(name :: term(), session_id(), pid()) :: :ok | {:error, term()}
  @callback lookup_session(name :: term(), session_id()) :: {:ok, pid()} | {:error, :not_found}
  @callback unregister_session(name :: term(), session_id()) :: :ok

  # Deterministic atom naming for internal processes

  @spec transport_name(module(), atom()) :: atom()
  def transport_name(server, type), do: :"Anubis.#{server}.transport.#{type}"

  @spec task_supervisor_name(module()) :: atom()
  def task_supervisor_name(server), do: :"Anubis.#{server}.task_supervisor"

  @spec session_supervisor_name(module()) :: atom()
  def session_supervisor_name(server), do: :"Anubis.#{server}.session_supervisor"

  @spec supervisor_name(module()) :: atom()
  def supervisor_name(server), do: :"Anubis.#{server}.supervisor"

  @spec session_name(module(), String.t()) :: atom()
  def session_name(server, session_id), do: :"Anubis.#{server}.session.#{session_id}"

  @spec stdio_session_name(module()) :: atom()
  def stdio_session_name(server), do: :"Anubis.#{server}.session.stdio"

  @spec registry_name(module()) :: atom()
  def registry_name(server), do: :"Anubis.#{server}.registry"
end
