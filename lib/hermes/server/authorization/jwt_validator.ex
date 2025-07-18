defmodule Hermes.Server.Authorization.JWTValidator do
  @moduledoc """
  JWT token validator for OAuth 2.1 authorization.

  Validates JWT tokens by fetching public keys from a JWKS (JSON Web Key Set) endpoint
  and verifying the token signature and claims. Supports RSA (RS256/RS384/RS512) and 
  ECDSA (ES256/ES384/ES512) algorithms.

  ## Configuration

      auth_config = [
        authorization_servers: ["https://auth.example.com"],
        realm: "my-app-realm",
        validator: Hermes.Server.Authorization.JWTValidator,
        
        # Required
        jwks_uri: "https://auth.example.com/.well-known/jwks.json",
        
        # Optional
        issuer: "https://auth.example.com",      # Validates iss claim
        audience: "https://api.example.com"      # Validates aud claim
      ]

  ## Features

  - Automatic JWKS caching (5 minutes TTL)
  - Key selection by kid (key ID) claim
  - Standard claims validation (exp, iss, aud)
  - Support for both RSA and EC keys

  ## Token Info

  Returns token information in the format expected by the authorization system:

      %{
        sub: "user123",              # Subject (user ID)
        aud: "https://api.example",  # Audience
        scope: "read write",         # OAuth scopes
        exp: 1234567890,            # Expiration timestamp
        iat: 1234567800,            # Issued at timestamp
        client_id: "app123",        # OAuth client ID
        active: true                # Always true for valid tokens
      }
  """

  @behaviour Hermes.Server.Authorization.Validator

  require Logger

  @jwks_cache_ttl to_timeout(minute: 5)

  @impl true
  def validate_token(token, config) do
    with {:ok, jwks} <- fetch_jwks(config),
         {:ok, header} <- peek_jwt_header(token),
         {:ok, key} <- find_signing_key(header, jwks),
         {:ok, claims} <- verify_and_decode(token, key, config),
         :ok <- validate_claims(claims, config) do
      {:ok, build_token_info(claims)}
    else
      {:error, :expired} -> {:error, :expired_token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches JWKS from the configured endpoint with caching.
  """
  def fetch_jwks(%{jwks_uri: jwks_uri}) when is_binary(jwks_uri) do
    cache_key = {:jwks, jwks_uri}
    now = System.monotonic_time(:millisecond)

    case Process.get(cache_key) do
      {jwks, expires_at} when expires_at > now ->
        {:ok, jwks}

      _ ->
        with {:ok, jwks} <- fetch_jwks_from_uri(jwks_uri) do
          expires_at = System.monotonic_time(:millisecond) + @jwks_cache_ttl
          Process.put(cache_key, {jwks, expires_at})
          {:ok, jwks}
        end
    end
  end

  def fetch_jwks(_), do: {:error, :no_jwks_uri}

  defp fetch_jwks_from_uri(uri) do
    with {:ok, request} <- Hermes.HTTP.build(:get, uri),
         {:ok, %Finch.Response{status: 200, body: body}} <- Finch.request(request, Hermes.Finch),
         {:ok, %{"keys" => keys}} <- JSON.decode(body) do
      {:ok, keys}
    else
      {:ok, %Finch.Response{status: status}} ->
        {:error, {:jwks_fetch_failed, status}}

      {:ok, json} when is_map(json) ->
        {:error, :invalid_jwks}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp peek_jwt_header(token) do
    with [header_b64 | _] <- String.split(token, "."),
         {:ok, header_json} <- Base.url_decode64(header_b64, padding: false),
         {:ok, header} <- JSON.decode(header_json) do
      {:ok, header}
    else
      _ -> {:error, :invalid_jwt_format}
    end
  end

  defp find_signing_key(%{"kid" => kid, "alg" => alg}, jwks) do
    case Enum.find(jwks, &(&1["kid"] == kid && &1["alg"] == alg)) do
      nil -> {:error, :key_not_found}
      key -> {:ok, key}
    end
  end

  defp find_signing_key(%{"alg" => alg}, jwks) do
    # No kid specified, try to find by algorithm
    case Enum.find(jwks, &(&1["alg"] == alg)) do
      nil -> {:error, :key_not_found}
      key -> {:ok, key}
    end
  end

  defp find_signing_key(_, _), do: {:error, :no_algorithm}

  defp verify_and_decode(token, jwk, config) do
    # Using Joken for JWT verification
    with {:ok, signer} <- build_signer(jwk),
         {:ok, claims} <- Joken.verify_and_validate(token, signer, %{}, config) do
      {:ok, claims}
    else
      {:error, :signature_error} -> {:error, :invalid_signature}
      {:error, _} = error -> error
    end
  end

  defp build_signer(%{"kty" => "RSA"} = jwk) do
    with {:ok, key} <- jwk_to_rsa_key(jwk) do
      alg = String.to_atom(jwk["alg"] || "RS256")
      {:ok, Joken.Signer.create(alg, %{"pem" => key})}
    end
  end

  defp build_signer(%{"kty" => "EC"} = jwk) do
    with {:ok, key} <- jwk_to_ec_key(jwk) do
      alg = String.to_atom(jwk["alg"] || "ES256")
      {:ok, Joken.Signer.create(alg, %{"pem" => key})}
    end
  end

  defp build_signer(_), do: {:error, :unsupported_key_type}

  defp jwk_to_rsa_key(%{"n" => n, "e" => e}) do
    # Convert JWK to RSA public key
    with {:ok, n_bin} <- Base.url_decode64(n, padding: false),
         {:ok, e_bin} <- Base.url_decode64(e, padding: false) do
      modulus = :crypto.bytes_to_integer(n_bin)
      exponent = :crypto.bytes_to_integer(e_bin)

      public_key = {:RSAPublicKey, modulus, exponent}
      pem_entry = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)
      pem = :public_key.pem_encode([pem_entry])

      {:ok, pem}
    end
  end

  defp jwk_to_ec_key(%{"x" => x, "y" => y, "crv" => crv}) do
    # Convert JWK to EC public key
    with {:ok, x_bin} <- Base.url_decode64(x, padding: false),
         {:ok, y_bin} <- Base.url_decode64(y, padding: false),
         {:ok, curve} <- curve_from_crv(crv) do
      point = <<0x04, x_bin::binary, y_bin::binary>>
      public_key = {{:ECPoint, point}, {:namedCurve, curve}}

      pem_entry = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)
      pem = :public_key.pem_encode([pem_entry])

      {:ok, pem}
    end
  end

  defp curve_from_crv("P-256"), do: {:ok, :secp256r1}
  defp curve_from_crv("P-384"), do: {:ok, :secp384r1}
  defp curve_from_crv("P-521"), do: {:ok, :secp521r1}
  defp curve_from_crv(_), do: {:error, :unsupported_curve}

  defp validate_claims(claims, config) do
    with :ok <- validate_issuer(claims, config),
         :ok <- validate_audience(claims, config) do
      validate_expiration(claims)
    end
  end

  defp validate_issuer(%{"iss" => iss}, %{issuer: expected_iss}) when is_binary(expected_iss) do
    if iss == expected_iss, do: :ok, else: {:error, :invalid_issuer}
  end

  defp validate_issuer(_, _), do: :ok

  defp validate_audience(%{"aud" => aud}, %{audience: expected_aud}) when is_binary(expected_aud) do
    cond do
      is_binary(aud) and aud == expected_aud -> :ok
      is_list(aud) and expected_aud in aud -> :ok
      true -> {:error, :invalid_audience}
    end
  end

  defp validate_audience(_, _), do: :ok

  defp validate_expiration(%{"exp" => exp}) when is_integer(exp) do
    now = System.system_time(:second)
    if now < exp, do: :ok, else: {:error, :expired}
  end

  defp validate_expiration(_), do: :ok

  defp build_token_info(claims) do
    %{
      sub: claims["sub"],
      aud: claims["aud"],
      scope: claims["scope"],
      exp: claims["exp"],
      iat: claims["iat"],
      client_id: claims["client_id"] || claims["azp"],
      active: true
    }
  end
end
