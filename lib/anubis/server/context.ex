defmodule Anubis.Server.Context do
  @moduledoc """
  Read-only session and request context, set by the SDK before each callback.

  The Session process builds a fresh Context before every user callback invocation.
  Mutations have no lasting effect — the Session always overwrites it.

  For STDIO transport, `headers` is empty, `remote_ip` is nil, and `auth` is nil.
  For HTTP transport, headers are normalized to lowercase string keys.

  ## Auth field

  When OAuth 2.1 authorization is configured on the server, `auth` contains the
  normalized claims map extracted from the validated bearer token:

      %{
        sub: "user-id",
        aud: "https://api.example.com",
        scope: "tools:read tools:write",
        scopes: ["tools:read", "tools:write"],
        exp: 1_234_567_890,
        iat: 1_234_567_800,
        client_id: "client-abc",
        raw_claims: %{}
      }

  `auth` is `nil` when no authorization is configured or the transport is STDIO.

  ## Init meta field

  `init_meta` carries the `_meta` map the client sent on its `initialize`
  request params (the MCP extension namespace), available to every callback
  including `init/2`. Empty map when the client sent none. Metadata sent under
  `clientInfo._meta` is preserved inside `client_info` itself.
  """

  @type auth_claims :: %{
          sub: String.t() | nil,
          aud: String.t() | [String.t()] | nil,
          scope: String.t() | nil,
          scopes: [String.t()],
          exp: integer() | nil,
          iat: integer() | nil,
          client_id: String.t() | nil,
          raw_claims: map()
        }

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          client_info: map() | nil,
          init_meta: map(),
          headers: %{String.t() => String.t()},
          remote_ip: :inet.ip_address() | nil,
          auth: auth_claims() | nil
        }

  defstruct session_id: nil,
            client_info: nil,
            init_meta: %{},
            headers: %{},
            remote_ip: nil,
            auth: nil
end
