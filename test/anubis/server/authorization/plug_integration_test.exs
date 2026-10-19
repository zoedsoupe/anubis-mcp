defmodule Anubis.Server.Authorization.PlugIntegrationTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Anubis.Server.Authorization
  alias Anubis.Server.Registry.Local
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: SHTTPPlug

  @moduletag capture_log: true

  defmodule FakeServer do
    @moduledoc false
    use Anubis.Server,
      name: "fake-server",
      version: "1.0.0",
      capabilities: []

    def server_info, do: %{"name" => "fake-server", "version" => "1.0.0"}
    def server_capabilities, do: %{}
    def supported_protocol_versions, do: ["2025-03-26"]
    def server_instructions, do: nil
  end

  defmodule TelemetryOutcomeValidator do
    @moduledoc """
    Maps token strings to validator behaviors so each bounded telemetry
    outcome can be driven through the real plug flow.
    """

    @behaviour Anubis.Server.Authorization.Validator

    @impl true
    def validate_token("invalid-token", _config), do: {:error, :invalid_token}
    def validate_token("invalid-issuer-token", _config), do: {:error, :invalid_issuer}

    def validate_token("mismatched-audience-token", _config) do
      {:ok, OAuthTestHelper.claims(%{aud: "https://other.example.com"})}
    end

    def validate_token("expired-claims-token", _config) do
      {:ok, OAuthTestHelper.claims(%{exp: System.os_time(:second) - 1})}
    end

    def validate_token("invalid-expiry-token", _config) do
      {:ok, OAuthTestHelper.claims(%{exp: "not-a-timestamp"})}
    end

    def validate_token("validator-unavailable-token", _config) do
      {:error, {:jwks_request_failed, :nxdomain}}
    end

    def validate_token("unknown-validator-error-token", _config), do: {:error, "unrecognized failure"}

    def validate_token("crashing-token", _config), do: raise("jwks exploded")

    def validate_token(_token, _config), do: {:ok, OAuthTestHelper.claims()}
  end

  defp build_conn(method, path, headers \\ []) do
    conn =
      method
      |> Plug.Test.conn(path, nil)
      |> put_private(:plug_skip_csrf_protection, true)

    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
  end

  defp auth_config do
    Authorization.parse_config!(
      authorization_servers: ["https://auth.example.com"],
      resource: "https://api.example.com",
      realm: "mcp",
      scopes_supported: ["tools:read", "tools:write"],
      validator: {MockTokenValidator, []}
    )
  end

  defp setup_auth_config(_context) do
    :persistent_term.put({Anubis.Server.Supervisor, FakeServer, :authorization_config}, auth_config())

    :persistent_term.put(
      {Anubis.Server.Supervisor, FakeServer, :session_config},
      %{
        registry_mod: Local,
        task_supervisor: nil
      }
    )

    on_exit(fn ->
      :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :authorization_config})
      :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :session_config})
    end)

    :ok
  end

  describe "well-known endpoint" do
    setup :setup_auth_config

    test "responds 200 with JSON metadata at /.well-known/oauth-protected-resource" do
      conn =
        build_conn("GET", "/.well-known/oauth-protected-resource")

      opts = SHTTPPlug.init(server: FakeServer)

      conn = SHTTPPlug.call(conn, opts)

      assert conn.status == 200
      assert conn |> get_resp_header("content-type") |> hd() =~ "application/json"

      {:ok, body} = JSON.decode(conn.resp_body)
      assert body["resource"] == "https://api.example.com"
      assert body["authorization_servers"] == ["https://auth.example.com"]
      assert body["bearer_methods_supported"] == ["header"]
    end
  end

  describe "authorization enforcement" do
    setup :setup_auth_config

    test "returns 401 when Authorization header is missing" do
      conn = build_conn("POST", "/mcp", [{"accept", "application/json"}])

      opts = SHTTPPlug.init(server: FakeServer)
      conn = SHTTPPlug.call(conn, opts)

      assert conn.status == 401
      assert [www_auth] = get_resp_header(conn, "www-authenticate")
      assert www_auth =~ ~s(Bearer realm="mcp")
      assert www_auth =~ "resource_metadata="
    end

    test "returns 401 when token is invalid" do
      conn =
        build_conn("POST", "/mcp", [
          {"accept", "application/json"},
          {"authorization", "Bearer invalid-token"}
        ])

      opts = SHTTPPlug.init(server: FakeServer)
      conn = SHTTPPlug.call(conn, opts)

      assert conn.status == 401
    end

    test "returns 401 when token is expired" do
      conn =
        build_conn("POST", "/mcp", [
          {"accept", "application/json"},
          {"authorization", "Bearer expired-token"}
        ])

      opts = SHTTPPlug.init(server: FakeServer)
      conn = SHTTPPlug.call(conn, opts)

      assert conn.status == 401
    end
  end

  describe "authorization outcome telemetry" do
    setup do
      config =
        Authorization.parse_config!(
          authorization_servers: ["https://auth.example.com"],
          resource: "https://api.example.com",
          realm: "mcp",
          scopes_supported: ["tools:read"],
          validator: {TelemetryOutcomeValidator, []}
        )

      :persistent_term.put({Anubis.Server.Supervisor, FakeServer, :authorization_config}, config)

      :persistent_term.put(
        {Anubis.Server.Supervisor, FakeServer, :session_config},
        %{
          registry_mod: Local,
          task_supervisor: nil
        }
      )

      handler_id = "test-auth-outcome-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:anubis_mcp, :server, :authorization, :start],
          [:anubis_mcp, :server, :authorization, :stop],
          [:anubis_mcp, :server, :authorization, :exception],
          [:anubis_mcp, :server, :authorization, :validate]
        ],
        fn event, measurements, metadata, _ ->
          send(self(), {:auth_telemetry, event, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)

        :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :authorization_config})
        :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :session_config})
      end)

      :ok
    end

    defp request_with_token(token) do
      conn = build_conn("GET", "/mcp", [{"authorization", "Bearer " <> token}])
      opts = SHTTPPlug.init(server: FakeServer)
      SHTTPPlug.call(conn, opts)
    end

    defp assert_stop(outcome) do
      assert_received {:auth_telemetry, [:anubis_mcp, :server, :authorization, :stop], measurements, metadata}

      assert measurements.duration >= 0
      assert metadata.outcome == outcome
      metadata
    end

    test "emits :stop with outcome :ok when the token validates" do
      conn = request_with_token("valid-token")

      # Authorization passed and the request moved on to protocol handling.
      assert conn.status == 406

      assert_received {:auth_telemetry, [:anubis_mcp, :server, :authorization, :start], _,
                       %{validator: TelemetryOutcomeValidator}}

      assert_received {:auth_telemetry, [:anubis_mcp, :server, :authorization, :validate], _,
                       %{
                         validator: TelemetryOutcomeValidator
                       }}

      assert_stop(:ok)
    end

    test "emits :stop with outcome :missing_token when the bearer token is absent" do
      conn = build_conn("GET", "/mcp")
      opts = SHTTPPlug.init(server: FakeServer)
      conn = SHTTPPlug.call(conn, opts)

      assert conn.status == 401
      assert_stop(:missing_token)
    end

    test "emits :stop with outcome :invalid_token when the validator rejects the token" do
      conn = request_with_token("invalid-token")

      assert conn.status == 401

      # The deprecated single-shot event is still emitted during the window.
      assert_received {:auth_telemetry, [:anubis_mcp, :server, :authorization, :validate], _,
                       %{validator: TelemetryOutcomeValidator}}

      assert_stop(:invalid_token)
    end

    test "emits :stop with outcome :invalid_issuer when the validator rejects the issuer" do
      conn = request_with_token("invalid-issuer-token")

      assert conn.status == 401
      assert_stop(:invalid_issuer)
    end

    test "emits :stop with outcome :invalid_audience when the audience does not match" do
      conn = request_with_token("mismatched-audience-token")

      assert conn.status == 401
      assert_stop(:invalid_audience)
    end

    test "emits :stop with outcome :token_expired when the token has expired" do
      conn = request_with_token("expired-claims-token")

      assert conn.status == 401
      assert_stop(:token_expired)
    end

    test "emits :stop with outcome :invalid_expiry when the exp claim is malformed" do
      conn = request_with_token("invalid-expiry-token")

      assert conn.status == 401
      assert_stop(:invalid_expiry)
    end

    test "emits :stop with outcome :validator_unavailable when the validator cannot run" do
      conn = request_with_token("validator-unavailable-token")

      assert conn.status == 401
      assert_stop(:validator_unavailable)
    end

    test "emits :stop with outcome :other for unrecognized validator errors" do
      conn = request_with_token("unknown-validator-error-token")

      assert conn.status == 401
      assert_stop(:other)
    end

    test "emits :exception and re-raises when the validator crashes" do
      assert_raise RuntimeError, "jwks exploded", fn ->
        request_with_token("crashing-token")
      end

      assert_received {:auth_telemetry, [:anubis_mcp, :server, :authorization, :exception], measurements, metadata}

      assert measurements.duration >= 0
      assert metadata.kind == :error
      assert Map.has_key?(metadata, :reason)
    end

    test "telemetry metadata carries no tokens, claims or validator error details" do
      request_with_token("validator-unavailable-token")
      metadata = assert_stop(:validator_unavailable)

      refute inspect(metadata) =~ "validator-unavailable-token"
      refute inspect(metadata) =~ "jwks_request_failed"
      refute inspect(metadata) =~ "nxdomain"

      request_with_token("unknown-validator-error-token")
      metadata = assert_stop(:other)

      refute inspect(metadata) =~ "unknown-validator-error-token"
      refute inspect(metadata) =~ "unrecognized failure"

      request_with_token("claims-token")
      metadata = assert_stop(:ok)

      refute inspect(metadata) =~ "test-user"
      refute inspect(metadata) =~ "test-client"
      refute Map.has_key?(metadata, :claims)
      refute Map.has_key?(metadata, :token)
    end
  end

  describe "no authorization configured" do
    setup do
      :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :authorization_config})

      :persistent_term.put(
        {Anubis.Server.Supervisor, FakeServer, :session_config},
        %{
          registry_mod: Anubis.Server.Registry.None,
          task_supervisor: nil
        }
      )

      :persistent_term.put(
        {Anubis.Server.Supervisor, FakeServer, :session_supervisor_mod},
        DynamicSupervisor
      )

      on_exit(fn ->
        :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :session_config})
        :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :session_supervisor_mod})
      end)

      :ok
    end

    test "returns 404 on well-known path when no auth configured" do
      conn = build_conn("GET", "/.well-known/oauth-protected-resource")
      opts = SHTTPPlug.init(server: FakeServer)
      conn = SHTTPPlug.call(conn, opts)

      assert conn.status == 404
    end
  end

  describe "Anubis.Server.Transport.WellKnown plug" do
    alias Anubis.Server.Transport.WellKnown

    setup do
      config = auth_config()
      :persistent_term.put({Anubis.Server.Supervisor, FakeServer, :authorization_config}, config)

      on_exit(fn ->
        :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :authorization_config})
      end)

      :ok
    end

    test "serves metadata even when invoked outside the SSE/StreamableHTTP mount" do
      conn = build_conn("GET", "/")
      opts = WellKnown.init(server: FakeServer)
      conn = WellKnown.call(conn, opts)

      assert conn.status == 200
      assert conn |> get_resp_header("content-type") |> hd() =~ "application/json"

      {:ok, body} = JSON.decode(conn.resp_body)
      assert body["resource"] == "https://api.example.com"
      assert body["authorization_servers"] == ["https://auth.example.com"]
    end

    test "returns 404 when authorization config is absent" do
      :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :authorization_config})

      conn = build_conn("GET", "/")
      opts = WellKnown.init(server: FakeServer)
      conn = WellKnown.call(conn, opts)

      assert conn.status == 404
    end
  end
end
