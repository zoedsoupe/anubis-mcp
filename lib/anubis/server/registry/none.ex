defmodule Anubis.Server.Registry.None do
  @moduledoc """
  No-op registry for STDIO transport.

  STDIO has exactly one session, looked up by atom name. No registry needed.
  """

  @behaviour Anubis.Server.Registry

  @impl Anubis.Server.Registry
  def child_spec(_opts), do: :ignore

  @impl Anubis.Server.Registry
  def register_session(_name, _session_id, _pid), do: :ok

  @impl Anubis.Server.Registry
  def lookup_session(_name, _session_id), do: {:error, :not_found}

  @impl Anubis.Server.Registry
  def unregister_session(_name, _session_id), do: :ok
end
