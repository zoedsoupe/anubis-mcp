defmodule Anubis.Server.Context do
  @moduledoc """
  Read-only session and request context, set by the SDK before each callback.

  The Session process builds a fresh Context before every user callback invocation.
  Mutations have no lasting effect — the Session always overwrites it.

  For STDIO transport, `headers` is empty and `remote_ip` is nil.
  For HTTP transport, headers are normalized to lowercase string keys.
  """

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          client_info: map() | nil,
          headers: %{String.t() => String.t()},
          remote_ip: :inet.ip_address() | nil
        }

  defstruct session_id: nil,
            client_info: nil,
            headers: %{},
            remote_ip: nil
end
