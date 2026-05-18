if Code.ensure_loaded?(JOSE) do
  defmodule Anubis.Server.Authorization.JWTValidator do
    @moduledoc """
    JWT validator using JWKS (requires the `:jose` dependency).

    Fetches the JWKS from the configured URI, caches the key set in
    `:persistent_term` with a 5-minute TTL, then verifies the token
    signature against the matching key.

    Issuer validation is performed here when `:issuer` is configured.
    `aud` and `exp` are validated by the authorization plug layer
    (`Anubis.Server.Authorization.validate_audience/2` and
    `validate_expiry/1`) after the validator returns claims.

    ## Configuration

        validator: {Anubis.Server.Authorization.JWTValidator,
          jwks_uri: "https://auth.example.com/.well-known/jwks.json",
          issuer: "https://auth.example.com"   # optional, enables iss validation
        }

    ## Options

      * `:jwks_uri` — URL of the JWKS endpoint (required)
      * `:issuer` — expected `iss` claim value (optional)

    ## JOSE Dependency

    This module only exists when `:jose ~> 1.11` is present in the project deps.
    Add it to your `mix.exs`:

        {:jose, "~> 1.11"}
    """

    @behaviour Anubis.Server.Authorization.Validator

    use Anubis.Logging

    @jwks_ttl_seconds 300
    @http_receive_timeout 5_000
    @http_pool_timeout 1_000

    @spec validate_token(String.t(), map()) :: {:ok, map()} | {:error, term()}
    @impl true
    def validate_token(token, %{validator: {_mod, opts}}) when is_binary(token) and is_list(opts) do
      jwks_uri = Keyword.fetch!(opts, :jwks_uri)

      with {:ok, jwks} <- fetch_jwks(jwks_uri),
           {:ok, claims} <- verify_token(token, jwks),
           :ok <- maybe_validate_issuer(claims, opts) do
        {:ok, claims}
      end
    end

    defp fetch_jwks(jwks_uri) do
      cache_key = {__MODULE__, :jwks, jwks_uri}

      case :persistent_term.get(cache_key, nil) do
        {jwks, cached_at} when is_map(jwks) ->
          if System.os_time(:second) - cached_at < @jwks_ttl_seconds do
            {:ok, jwks}
          else
            do_fetch_jwks(jwks_uri, cache_key)
          end

        _ ->
          do_fetch_jwks(jwks_uri, cache_key)
      end
    end

    defp do_fetch_jwks(jwks_uri, cache_key) do
      request = Finch.build(:get, jwks_uri, [{"accept", "application/json"}])

      case Finch.request(request, Anubis.Finch,
             receive_timeout: @http_receive_timeout,
             pool_timeout: @http_pool_timeout
           ) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          case JSON.decode(body) do
            {:ok, jwks} ->
              :persistent_term.put(cache_key, {jwks, System.os_time(:second)})
              {:ok, jwks}

            {:error, reason} ->
              Logging.server_event("jwks_parse_error", %{reason: inspect(reason)}, level: :error)
              {:error, :invalid_jwks_response}
          end

        {:ok, %Finch.Response{status: status}} ->
          Logging.server_event("jwks_fetch_error", %{status: status, uri: jwks_uri}, level: :error)
          {:error, {:jwks_fetch_failed, status}}

        {:error, reason} ->
          Logging.server_event("jwks_request_failed", %{reason: inspect(reason)}, level: :error)
          {:error, {:jwks_request_failed, reason}}
      end
    end

    defp verify_token(token, jwks) do
      keys = Map.get(jwks, "keys", [])

      try do
        candidates = candidate_keys(token, keys)
        verify_with_keys(candidates, token)
      rescue
        e ->
          Logging.server_event("jwt_verify_error", %{error: inspect(e)}, level: :warning)
          {:error, :jwt_verification_failed}
      end
    end

    defp candidate_keys(token, keys) do
      case peek_kid(token) do
        nil -> keys
        kid -> keys |> Enum.filter(&(Map.get(&1, "kid") == kid)) |> fallback(keys)
      end
    end

    defp fallback([], all), do: all
    defp fallback(matches, _all), do: matches

    defp peek_kid(token) do
      with %JOSE.JWS{fields: fields} <- token |> JOSE.JWS.peek_protected() |> JOSE.JWS.from() do
        Map.get(fields, "kid")
      end
    rescue
      _ -> nil
    end

    defp verify_with_keys([], _token), do: {:error, :invalid_signature}

    defp verify_with_keys([key | rest], token) do
      jwk = JOSE.JWK.from_map(key)

      case JOSE.JWT.verify_strict(jwk, supported_algorithms(), token) do
        {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
        _ -> verify_with_keys(rest, token)
      end
    end

    defp maybe_validate_issuer(claims, opts) do
      case Keyword.get(opts, :issuer) do
        nil ->
          :ok

        expected_issuer ->
          actual_issuer = claims["iss"]

          if actual_issuer == expected_issuer do
            :ok
          else
            {:error, :invalid_issuer}
          end
      end
    end

    defp supported_algorithms do
      ["RS256", "RS384", "RS512", "ES256", "ES384", "ES512", "PS256", "PS384", "PS512"]
    end
  end
end
