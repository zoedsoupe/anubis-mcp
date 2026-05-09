if Code.ensure_loaded?(JOSE) do
  defmodule Anubis.Server.Authorization.JWTValidatorTest do
    use ExUnit.Case, async: true

    alias Anubis.Server.Authorization
    alias Anubis.Server.Authorization.JWTValidator

    @moduletag capture_log: true

    setup do
      {private_key, public_jwks} = generate_rsa_keypair()
      {:ok, private_key: private_key, public_jwks: public_jwks}
    end

    defp generate_rsa_keypair do
      private_jwk = JOSE.JWK.generate_key({:rsa, 2048})
      public_jwk = JOSE.JWK.to_public(private_jwk)
      {_, public_map} = JOSE.JWK.to_map(public_jwk)
      jwks = %{"keys" => [Map.put(public_map, "use", "sig")]}
      {private_jwk, jwks}
    end

    defp sign_token(private_key, claims) do
      header = %{"alg" => "RS256", "typ" => "JWT"}
      {_, token} = private_key |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
      token
    end

    defp build_config(bypass, extra_opts \\ []) do
      jwks_url = "http://localhost:#{bypass.port}/jwks"

      base_opts = [
        authorization_servers: ["https://auth.example.com"],
        resource: "https://api.example.com",
        validator: {JWTValidator, Keyword.merge([jwks_uri: jwks_url], extra_opts)}
      ]

      Authorization.parse_config!(base_opts)
    end

    defp setup_jwks_bypass(bypass, jwks) do
      Bypass.stub(bypass, "GET", "/jwks", fn conn ->
        Plug.Conn.send_resp(conn, 200, JSON.encode!(jwks))
      end)
    end

    defp valid_claims do
      now = System.os_time(:second)

      %{
        "sub" => "test-user",
        "aud" => "https://api.example.com",
        "iss" => "https://auth.example.com",
        "scope" => "tools:read",
        "exp" => now + 3600,
        "iat" => now
      }
    end

    describe "validate_token/2 — valid token" do
      test "returns ok with claims for valid signed token", %{private_key: key, public_jwks: jwks} do
        bypass = Bypass.open()
        setup_jwks_bypass(bypass, jwks)
        config = build_config(bypass)

        token = sign_token(key, valid_claims())

        assert {:ok, claims} = JWTValidator.validate_token(token, config)
        assert claims["sub"] == "test-user"
        assert claims["aud"] == "https://api.example.com"
      end

      test "validates issuer when configured", %{private_key: key, public_jwks: jwks} do
        bypass = Bypass.open()
        setup_jwks_bypass(bypass, jwks)
        config = build_config(bypass, issuer: "https://auth.example.com")

        token = sign_token(key, valid_claims())

        assert {:ok, _claims} = JWTValidator.validate_token(token, config)
      end
    end

    describe "validate_token/2 — invalid signature" do
      test "returns error for token signed with different key", %{public_jwks: jwks} do
        bypass = Bypass.open()
        setup_jwks_bypass(bypass, jwks)
        config = build_config(bypass)

        {other_key, _} = generate_rsa_keypair()
        token = sign_token(other_key, valid_claims())

        assert {:error, :invalid_signature} = JWTValidator.validate_token(token, config)
      end

      test "returns error for malformed token", %{public_jwks: jwks} do
        bypass = Bypass.open()
        setup_jwks_bypass(bypass, jwks)
        config = build_config(bypass)

        assert {:error, _} = JWTValidator.validate_token("not.a.jwt", config)
      end
    end

    describe "validate_token/2 — issuer validation" do
      test "returns error when issuer does not match", %{private_key: key, public_jwks: jwks} do
        bypass = Bypass.open()
        setup_jwks_bypass(bypass, jwks)
        config = build_config(bypass, issuer: "https://expected.example.com")

        claims = Map.put(valid_claims(), "iss", "https://other.example.com")
        token = sign_token(key, claims)

        assert {:error, :invalid_issuer} = JWTValidator.validate_token(token, config)
      end

      test "skips issuer validation when not configured", %{private_key: key, public_jwks: jwks} do
        bypass = Bypass.open()
        setup_jwks_bypass(bypass, jwks)
        config = build_config(bypass)

        claims = Map.delete(valid_claims(), "iss")
        token = sign_token(key, claims)

        assert {:ok, _} = JWTValidator.validate_token(token, config)
      end
    end

    describe "validate_token/2 — JWKS fetch errors" do
      test "returns error when JWKS endpoint is unreachable" do
        config =
          Authorization.parse_config!(
            authorization_servers: ["https://auth.example.com"],
            resource: "https://api.example.com",
            validator: {JWTValidator, jwks_uri: "http://localhost:1/jwks"}
          )

        assert {:error, _} = JWTValidator.validate_token("any.token.here", config)
      end

      test "returns error on non-200 JWKS response", %{public_jwks: jwks} do
        bypass = Bypass.open()
        setup_jwks_bypass(bypass, jwks)
        # Close Bypass to simulate 503
        Bypass.down(bypass)

        config = build_config(bypass)

        assert {:error, _} = JWTValidator.validate_token("any.token.here", config)
      end
    end
  end
end
