defmodule Anubis.Server.AuthorizationTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Authorization

  describe "parse_config!/1" do
    test "parses valid config" do
      config =
        Authorization.parse_config!(
          authorization_servers: ["https://auth.example.com"],
          resource: "https://api.example.com",
          validator: {MockTokenValidator, []}
        )

      assert config.authorization_servers == ["https://auth.example.com"]
      assert config.resource == "https://api.example.com"
      assert config.realm == "mcp"
      assert config.scopes_supported == []
      assert config.validator == {MockTokenValidator, []}
    end

    test "applies defaults for realm and scopes_supported" do
      config =
        Authorization.parse_config!(
          authorization_servers: ["https://auth.example.com"],
          resource: "https://api.example.com",
          validator: {MockTokenValidator, []}
        )

      assert config.realm == "mcp"
      assert config.scopes_supported == []
    end

    test "accepts custom realm and scopes_supported" do
      config =
        Authorization.parse_config!(
          authorization_servers: ["https://auth.example.com"],
          resource: "https://api.example.com",
          realm: "my-realm",
          scopes_supported: ["tools:read", "tools:write"],
          validator: {MockTokenValidator, []}
        )

      assert config.realm == "my-realm"
      assert config.scopes_supported == ["tools:read", "tools:write"]
    end

    test "raises Peri.InvalidSchema when authorization_servers is missing" do
      assert_raise Peri.InvalidSchema, ~r/authorization_servers/, fn ->
        Authorization.parse_config!(
          resource: "https://api.example.com",
          validator: {MockTokenValidator, []}
        )
      end
    end

    test "raises Peri.InvalidSchema when resource is missing" do
      assert_raise Peri.InvalidSchema, ~r/resource/, fn ->
        Authorization.parse_config!(
          authorization_servers: ["https://auth.example.com"],
          validator: {MockTokenValidator, []}
        )
      end
    end

    test "raises Peri.InvalidSchema when validator is missing" do
      assert_raise Peri.InvalidSchema, ~r/validator/, fn ->
        Authorization.parse_config!(
          authorization_servers: ["https://auth.example.com"],
          resource: "https://api.example.com"
        )
      end
    end

    test "raises Peri.InvalidSchema when validator has wrong shape" do
      assert_raise Peri.InvalidSchema, fn ->
        Authorization.parse_config!(
          authorization_servers: ["https://auth.example.com"],
          resource: "https://api.example.com",
          validator: :not_a_tuple
        )
      end
    end
  end

  describe "build_resource_metadata/1" do
    setup do
      config =
        Authorization.parse_config!(
          authorization_servers: ["https://auth.example.com"],
          resource: "https://api.example.com",
          scopes_supported: ["tools:read", "tools:write"],
          validator: {MockTokenValidator, []}
        )

      {:ok, config: config}
    end

    test "returns RFC 9728 metadata map", %{config: config} do
      metadata = Authorization.build_resource_metadata(config)

      assert metadata["resource"] == "https://api.example.com"
      assert metadata["authorization_servers"] == ["https://auth.example.com"]
      assert metadata["scopes_supported"] == ["tools:read", "tools:write"]
      assert metadata["bearer_methods_supported"] == ["header"]
    end
  end

  describe "build_www_authenticate/2" do
    setup do
      config =
        Authorization.parse_config!(
          authorization_servers: ["https://auth.example.com"],
          resource: "https://api.example.com",
          realm: "mcp",
          validator: {MockTokenValidator, []}
        )

      {:ok, config: config}
    end

    test "builds 401 header with resource_metadata URL", %{config: config} do
      header = Authorization.build_www_authenticate(config, :unauthorized)

      assert header =~ ~s(Bearer realm="mcp")
      assert header =~ ~s(resource_metadata="https://api.example.com/.well-known/oauth-protected-resource")
    end

    test "builds 403 header with insufficient_scope", %{config: config} do
      header = Authorization.build_www_authenticate(config, {:insufficient_scope, "tools:write"})

      assert header =~ ~s(error="insufficient_scope")
      assert header =~ ~s(scope="tools:write")
    end
  end

  describe "validate_audience/2" do
    setup do
      config =
        Authorization.parse_config!(
          authorization_servers: ["https://auth.example.com"],
          resource: "https://api.example.com",
          validator: {MockTokenValidator, []}
        )

      {:ok, config: config}
    end

    test "returns :ok when aud string matches resource", %{config: config} do
      claims = %{aud: "https://api.example.com"}
      assert :ok == Authorization.validate_audience(claims, config)
    end

    test "returns :ok when aud list includes resource", %{config: config} do
      claims = %{aud: ["https://api.example.com", "https://other.example.com"]}
      assert :ok == Authorization.validate_audience(claims, config)
    end

    test "returns error when aud string does not match", %{config: config} do
      claims = %{aud: "https://other.example.com"}
      assert {:error, :invalid_audience} == Authorization.validate_audience(claims, config)
    end

    test "returns error when aud list does not include resource", %{config: config} do
      claims = %{aud: ["https://other.example.com"]}
      assert {:error, :invalid_audience} == Authorization.validate_audience(claims, config)
    end

    test "returns error when aud is missing", %{config: config} do
      assert {:error, :invalid_audience} == Authorization.validate_audience(%{}, config)
    end
  end

  describe "validate_expiry/1" do
    test "returns :ok for non-expired token" do
      claims = %{exp: System.os_time(:second) + 3600}
      assert :ok == Authorization.validate_expiry(claims)
    end

    test "returns error for expired token" do
      claims = %{exp: System.os_time(:second) - 1}
      assert {:error, :token_expired} == Authorization.validate_expiry(claims)
    end

    test "returns :ok when exp is nil" do
      assert :ok == Authorization.validate_expiry(%{exp: nil})
    end

    test "returns :ok when exp is absent" do
      assert :ok == Authorization.validate_expiry(%{})
    end

    test "returns error for non-integer exp" do
      assert {:error, :invalid_expiry} == Authorization.validate_expiry(%{exp: "2024-01-01"})
      assert {:error, :invalid_expiry} == Authorization.validate_expiry(%{exp: 1.5})
    end

    test "returns error for negative exp" do
      assert {:error, :invalid_expiry} == Authorization.validate_expiry(%{exp: -1})
    end
  end

  describe "validate_scopes/2" do
    test "returns :ok when required list is empty" do
      claims = %{scopes: []}
      assert :ok == Authorization.validate_scopes(claims, [])
    end

    test "returns :ok when all required scopes are granted" do
      claims = %{scopes: ["tools:read", "tools:write"]}
      assert :ok == Authorization.validate_scopes(claims, ["tools:read"])
      assert :ok == Authorization.validate_scopes(claims, ["tools:read", "tools:write"])
    end

    test "returns error when some scopes are missing" do
      claims = %{scopes: ["tools:read"]}

      assert {:error, {:insufficient_scope, ["tools:write"]}} ==
               Authorization.validate_scopes(claims, ["tools:read", "tools:write"])
    end

    test "returns error when all scopes are missing" do
      claims = %{scopes: []}

      assert {:error, {:insufficient_scope, ["tools:read"]}} ==
               Authorization.validate_scopes(claims, ["tools:read"])
    end
  end

  describe "well_known_url/1" do
    test "appends /.well-known/oauth-protected-resource" do
      url = Authorization.well_known_url("https://api.example.com")
      assert url == "https://api.example.com/.well-known/oauth-protected-resource"
    end

    test "strips path from resource URI" do
      url = Authorization.well_known_url("https://api.example.com/v1")
      assert url == "https://api.example.com/.well-known/oauth-protected-resource"
    end
  end

  describe "normalize_claims/1" do
    test "normalizes string-keyed map" do
      now = System.os_time(:second)

      raw = %{
        "sub" => "user-1",
        "aud" => "https://api.example.com",
        "scope" => "tools:read tools:write",
        "exp" => now + 3600,
        "iat" => now,
        "client_id" => "client-abc"
      }

      claims = Authorization.normalize_claims(raw)

      assert claims.sub == "user-1"
      assert claims.aud == "https://api.example.com"
      assert claims.scope == "tools:read tools:write"
      assert claims.scopes == ["tools:read", "tools:write"]
      assert claims.exp == now + 3600
      assert claims.iat == now
      assert claims.client_id == "client-abc"
      assert claims.raw_claims == raw
    end

    test "handles missing optional fields" do
      claims = Authorization.normalize_claims(%{"sub" => "u1"})

      assert claims.sub == "u1"
      assert is_nil(claims.aud)
      assert is_nil(claims.scope)
      assert claims.scopes == []
      assert is_nil(claims.exp)
    end

    test "preserves pre-normalized scopes list with string keys" do
      claims = Authorization.normalize_claims(%{"sub" => "u1", "scopes" => ["tools:read", "tools:write"]})

      assert claims.scopes == ["tools:read", "tools:write"]
      assert is_nil(claims.scope)
    end

    test "preserves pre-normalized scopes list with atom keys" do
      claims = Authorization.normalize_claims(%{sub: "u1", scopes: ["tools:read"]})

      assert claims.scopes == ["tools:read"]
    end

    test "prefers pre-normalized scopes over scope string" do
      claims = Authorization.normalize_claims(%{"scope" => "ignored", "scopes" => ["kept"]})

      assert claims.scopes == ["kept"]
      assert claims.scope == "ignored"
    end
  end
end
