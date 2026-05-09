defmodule Anubis.Server.Authorization.IntrospectionValidatorTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Authorization
  alias Anubis.Server.Authorization.IntrospectionValidator

  @moduletag capture_log: true

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  defp build_config(bypass, extra_validator_opts \\ []) do
    validator_opts =
      [introspection_endpoint: OAuthTestHelper.introspection_url(bypass)] ++ extra_validator_opts

    Authorization.parse_config!(
      authorization_servers: ["https://auth.example.com"],
      resource: "https://api.example.com",
      validator: {IntrospectionValidator, validator_opts}
    )
  end

  describe "validate_token/2 — active token" do
    test "returns ok with claims for active token", %{bypass: bypass} do
      OAuthTestHelper.setup_introspection_bypass(bypass, respond: :active)
      config = build_config(bypass)

      assert {:ok, claims} = IntrospectionValidator.validate_token("my-token", config)
      assert claims["active"] == true
      assert claims["sub"] == "test-user"
    end

    test "sends token as form-encoded body", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/introspect", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, body})
        Plug.Conn.send_resp(conn, 200, OAuthTestHelper.active_introspection_response())
      end)

      config = build_config(bypass)
      IntrospectionValidator.validate_token("my-special-token", config)

      assert_receive {:body, body}
      params = URI.decode_query(body)
      assert params["token"] == "my-special-token"
      assert params["token_type_hint"] == "access_token"
    end
  end

  describe "validate_token/2 — inactive token" do
    test "returns error for inactive token", %{bypass: bypass} do
      OAuthTestHelper.setup_introspection_bypass(bypass, respond: :inactive)
      config = build_config(bypass)

      assert {:error, :token_inactive} = IntrospectionValidator.validate_token("bad-token", config)
    end
  end

  describe "validate_token/2 — HTTP errors" do
    test "returns error on non-200 response", %{bypass: bypass} do
      OAuthTestHelper.setup_introspection_bypass(bypass, respond: {:error, 500})
      config = build_config(bypass)

      assert {:error, {:introspection_error, 500}} =
               IntrospectionValidator.validate_token("any-token", config)
    end

    test "returns error when endpoint is unreachable" do
      config =
        Authorization.parse_config!(
          authorization_servers: ["https://auth.example.com"],
          resource: "https://api.example.com",
          validator: {IntrospectionValidator, introspection_endpoint: "http://localhost:1"}
        )

      assert {:error, _} = IntrospectionValidator.validate_token("any-token", config)
    end
  end

  describe "Basic auth credentials" do
    test "includes Authorization header when credentials are configured", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/introspect", fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:auth, auth_header})
        Plug.Conn.send_resp(conn, 200, OAuthTestHelper.active_introspection_response())
      end)

      config = build_config(bypass, client_id: "my-client", client_secret: "my-secret")
      IntrospectionValidator.validate_token("token", config)

      assert_receive {:auth, [auth_value]}
      assert auth_value =~ "Basic "

      expected = Base.encode64("my-client:my-secret")
      assert auth_value == "Basic #{expected}"
    end

    test "sends no Authorization header when no credentials", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/introspect", fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:auth, auth_header})
        Plug.Conn.send_resp(conn, 200, OAuthTestHelper.active_introspection_response())
      end)

      config = build_config(bypass)
      IntrospectionValidator.validate_token("token", config)

      assert_receive {:auth, []}
    end
  end
end
