defmodule Anubis.Server.Authorization.Validator do
  @moduledoc """
  Behaviour for token validators.

  Implement this behaviour to plug in a custom token validation strategy.
  Two built-in implementations are provided:

    * `Anubis.Server.Authorization.JWTValidator` — validates JWTs using JWKS (requires `:jose`)
    * `Anubis.Server.Authorization.IntrospectionValidator` — validates opaque tokens via RFC 7662

  ## Example

      defmodule MyApp.CustomValidator do
        @behaviour Anubis.Server.Authorization.Validator

        @impl true
        def validate_token(token, _config) do
          case MyApp.TokenStore.lookup(token) do
            {:ok, claims} -> {:ok, claims}
            :error -> {:error, :token_not_found}
          end
        end
      end
  """

  @type token :: String.t()
  @type config :: Anubis.Server.Authorization.config()
  @type claims :: map()
  @type reason :: atom() | String.t() | {atom(), term()}

  @doc """
  Validates a bearer token and returns normalized raw claims on success.

  The returned map should contain string keys as received from the token source.
  `Anubis.Server.Authorization.normalize_claims/1` is called by the authorization
  layer to convert it to the canonical claims shape stored in `Context.auth`.

  Returns `{:ok, raw_claims}` or `{:error, reason}`.
  """
  @callback validate_token(token(), config()) :: {:ok, claims()} | {:error, reason()}
end
