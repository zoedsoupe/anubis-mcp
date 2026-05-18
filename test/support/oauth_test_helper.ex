defmodule OAuthTestHelper do
  @moduledoc """
  Helpers for testing OAuth 2.1 authorization in Anubis servers.

  Provides token building, mock validator construction, and fixtures for
  Bypass-based HTTP endpoint mocking.
  """

  @doc """
  Builds a normalized claims map suitable for injecting into `Context.auth`.

  Defaults to a non-expired token for `resource` with scopes `["tools:read"]`.
  """
  def claims(overrides \\ %{}) do
    now = System.os_time(:second)

    base = %{
      sub: "test-user",
      aud: "https://api.example.com",
      scope: "tools:read",
      scopes: ["tools:read"],
      exp: now + 3600,
      iat: now,
      client_id: "test-client",
      raw_claims: %{}
    }

    Map.merge(base, overrides)
  end

  @doc """
  Builds a minimal authorization config map (as if parsed by `Authorization.parse_config!/1`).
  """
  def auth_config(overrides \\ %{}) do
    base = %{
      authorization_servers: ["https://auth.example.com"],
      resource: "https://api.example.com",
      realm: "mcp",
      scopes_supported: ["tools:read", "tools:write"],
      validator: {MockTokenValidator, []}
    }

    Map.merge(base, overrides)
  end

  @doc """
  Returns a mock introspection response body for an active token.
  """
  def active_introspection_response(opts \\ []) do
    now = System.os_time(:second)

    JSON.encode!(%{
      "active" => true,
      "sub" => Keyword.get(opts, :sub, "test-user"),
      "aud" => Keyword.get(opts, :aud, "https://api.example.com"),
      "scope" => Keyword.get(opts, :scope, "tools:read"),
      "exp" => Keyword.get(opts, :exp, now + 3600),
      "iat" => Keyword.get(opts, :iat, now),
      "client_id" => Keyword.get(opts, :client_id, "test-client")
    })
  end

  @doc """
  Returns an inactive introspection response body.
  """
  def inactive_introspection_response do
    JSON.encode!(%{"active" => false})
  end

  @doc """
  Configures a Bypass instance to serve an introspection endpoint.

  The `respond` option controls what the endpoint returns:
  - `:active` — returns an active token response (default)
  - `:inactive` — returns an inactive token response
  - `{:error, status}` — returns an error HTTP status
  """
  def setup_introspection_bypass(bypass, opts \\ []) do
    respond = Keyword.get(opts, :respond, :active)

    Bypass.expect_once(bypass, "POST", "/introspect", fn conn ->
      case respond do
        :active ->
          Plug.Conn.send_resp(conn, 200, active_introspection_response(opts))

        :inactive ->
          Plug.Conn.send_resp(conn, 200, inactive_introspection_response())

        {:error, status} ->
          Plug.Conn.send_resp(conn, status, "error")
      end
    end)
  end

  @doc """
  Returns the introspection endpoint URL for a Bypass instance.
  """
  def introspection_url(bypass) do
    "http://localhost:#{bypass.port}/introspect"
  end
end

defmodule MockTokenValidator do
  @moduledoc """
  A simple test validator that accepts any non-empty token and returns
  configurable claims. Use `:persistent_term` or process dictionary for
  test-specific configuration.
  """

  @behaviour Anubis.Server.Authorization.Validator

  @impl true
  def validate_token("invalid-token", _config) do
    {:error, :invalid_token}
  end

  def validate_token("expired-token", _config) do
    {:ok,
     %{
       "sub" => "test-user",
       "aud" => "https://api.example.com",
       "scope" => "tools:read",
       "exp" => System.os_time(:second) - 1,
       "iat" => System.os_time(:second) - 3600
     }}
  end

  def validate_token(_token, _config) do
    now = System.os_time(:second)

    {:ok,
     %{
       "sub" => "test-user",
       "aud" => "https://api.example.com",
       "scope" => "tools:read tools:write",
       "exp" => now + 3600,
       "iat" => now,
       "client_id" => "test-client"
     }}
  end
end
