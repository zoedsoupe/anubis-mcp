defmodule Anubis.Client.AuthorizationTest do
  use ExUnit.Case, async: true

  alias Anubis.Client.Authorization
  alias Anubis.Client.Authorization.Challenge
  alias Anubis.Client.Authorization.Metadata

  setup do
    bypass = Bypass.open()
    origin = "http://localhost:#{bypass.port}"
    %{bypass: bypass, origin: origin, url: origin <> "/mcp", opts: [allow_insecure_localhost: true]}
  end

  test "discovers resource and OAuth endpoints proactively", ctx do
    resource(ctx, "/.well-known/oauth-protected-resource/mcp")
    issuer(ctx, "/.well-known/oauth-authorization-server/tenant")

    assert {:ok, metadata} = Authorization.discover(ctx.url, ctx.opts)
    assert metadata.__struct__ == Metadata
    assert metadata.resource == ctx.url
    assert metadata.mcp_url == ctx.url
    assert metadata.authorization_server == ctx.origin <> "/tenant"
    assert metadata.authorization_endpoint == ctx.origin <> "/authorize"
    assert metadata.token_endpoint == ctx.origin <> "/token"
    assert metadata.scopes_supported == ["read", "write"]
    assert metadata.code_challenge_methods_supported == ["S256"]
    assert metadata.challenge == nil
  end

  test "uses the challenge URL and preserves challenged scopes", ctx do
    raw = ~s(Bearer resource_metadata="#{ctx.origin}/metadata", scope="write admin", error="insufficient_scope")
    challenge = Challenge.from_response(ctx.url, 403, [{"www-authenticate", raw}])
    resource(ctx, "/metadata")
    issuer(ctx, "/.well-known/oauth-authorization-server/tenant")

    assert {:ok, metadata} = Authorization.discover(ctx.url, Keyword.put(ctx.opts, :challenge, challenge))
    assert metadata.resource_metadata_uri == ctx.origin <> "/metadata"
    assert metadata.challenge.headers == [raw]
    assert metadata.challenge.scope == "write admin"
    assert metadata.scopes_supported == ["read", "write"]
  end

  test "parses multiple schemes, quoted commas, escaped quotes and case-insensitive names" do
    raw =
      ~S(Basic realm="other", bEaReR realm="a,b\"c", resource_metadata="https://example.com/meta", scope = "read write")

    challenge = Challenge.from_response("https://example.com/mcp", 401, [{"WWW-Authenticate", raw}])
    assert challenge.resource_metadata == "https://example.com/meta"
    assert challenge.scope == "read write"
    assert challenge.headers == [raw]
  end

  test "falls back from path-specific metadata to root metadata", ctx do
    missing(ctx, "/.well-known/oauth-protected-resource/mcp")
    resource(ctx, "/.well-known/oauth-protected-resource", %{"resource" => ctx.origin})
    issuer(ctx, "/.well-known/oauth-authorization-server/tenant")
    assert {:ok, metadata} = Authorization.discover(ctx.url, ctx.opts)
    assert metadata.resource == ctx.origin
    assert metadata.mcp_url == ctx.url
  end

  test "root metadata can describe the MCP endpoint", ctx do
    missing(ctx, "/.well-known/oauth-protected-resource/mcp")
    resource(ctx, "/.well-known/oauth-protected-resource")
    issuer(ctx, "/.well-known/oauth-authorization-server/tenant")
    assert {:ok, metadata} = Authorization.discover(ctx.url, ctx.opts)
    assert metadata.resource == ctx.url
  end

  test "tries OAuth then OIDC insertion then OIDC appending for issuer paths", ctx do
    resource(ctx, "/.well-known/oauth-protected-resource/mcp")
    missing(ctx, "/.well-known/oauth-authorization-server/tenant")
    missing(ctx, "/.well-known/openid-configuration/tenant")
    issuer(ctx, "/tenant/.well-known/openid-configuration")
    assert {:ok, _} = Authorization.discover(ctx.url, ctx.opts)
  end

  test "supports OIDC discovery for issuers without paths", ctx do
    resource(ctx, "/.well-known/oauth-protected-resource/mcp", %{"authorization_servers" => [ctx.origin]})
    missing(ctx, "/.well-known/oauth-authorization-server")
    issuer(ctx, "/.well-known/openid-configuration", %{"issuer" => ctx.origin})
    assert {:ok, metadata} = Authorization.discover(ctx.url, ctx.opts)
    assert metadata.authorization_server == ctx.origin
  end

  test "rejects metadata for a different resource without trying another location", ctx do
    resource(ctx, "/.well-known/oauth-protected-resource/mcp", %{"resource" => ctx.origin <> "/other"})
    assert {:error, %{reason: :resource_mismatch}} = Authorization.discover(ctx.url, ctx.opts)
  end

  test "rejects an issuer mismatch without falling through to OIDC", ctx do
    resource(ctx, "/.well-known/oauth-protected-resource/mcp")
    issuer(ctx, "/.well-known/oauth-authorization-server/tenant", %{"issuer" => ctx.origin <> "/other"})
    assert {:error, %{reason: :issuer_mismatch}} = Authorization.discover(ctx.url, ctx.opts)
  end

  test "requires explicit selection when multiple authorization servers are advertised", ctx do
    servers = [ctx.origin <> "/tenant", "https://another.example"]
    resource(ctx, "/.well-known/oauth-protected-resource/mcp", %{"authorization_servers" => servers})
    assert {:error, error} = Authorization.discover(ctx.url, ctx.opts)
    assert error.reason == :authorization_server_selection_required
    assert error.data.authorization_servers == servers
  end

  test "uses the selected issuer only if it was advertised", ctx do
    resource(ctx, "/.well-known/oauth-protected-resource/mcp")
    opts = Keyword.put(ctx.opts, :authorization_server, "https://unadvertised.example")
    assert {:error, %{reason: :unadvertised_authorization_server}} = Authorization.discover(ctx.url, opts)
  end

  test "does not interpret missing metadata as authorization being unnecessary", ctx do
    missing(ctx, "/.well-known/oauth-protected-resource/mcp")
    missing(ctx, "/.well-known/oauth-protected-resource")
    assert {:error, %{reason: :metadata_not_found}} = Authorization.discover(ctx.url, ctx.opts)
  end

  test "rejects malformed metadata", ctx do
    resource(ctx, "/.well-known/oauth-protected-resource/mcp", %{"authorization_servers" => "not a list"})
    assert {:error, %{reason: :invalid_resource_metadata}} = Authorization.discover(ctx.url, ctx.opts)
  end

  test "rejects invalid JSON without falling back", ctx do
    Bypass.expect_once(ctx.bypass, "GET", "/.well-known/oauth-protected-resource/mcp", fn conn ->
      Plug.Conn.resp(conn, 200, "{")
    end)

    assert {:error, %{reason: :invalid_metadata_json}} = Authorization.discover(ctx.url, ctx.opts)
  end

  test "rejects insecure URLs by default and never fetches invalid URLs", ctx do
    for url <- [ctx.url, "https://user:secret@example.com/mcp", "https://example.com/mcp#fragment", "/mcp"] do
      assert {:error, %{reason: :invalid_discovery_url}} = Authorization.discover(url)
    end
  end

  test "applies the application's URL policy before fetching", ctx do
    policy = fn url ->
      assert url == ctx.origin <> "/.well-known/oauth-protected-resource/mcp"
      {:error, :blocked_by_host}
    end

    assert {:error, %{reason: :discovery_url_rejected}} =
             Authorization.discover(ctx.url, Keyword.put(ctx.opts, :url_policy, policy))
  end

  test "does not follow metadata redirects", ctx do
    Bypass.expect_once(ctx.bypass, "GET", "/.well-known/oauth-protected-resource/mcp", fn conn ->
      conn |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/private") |> Plug.Conn.resp(302, "")
    end)

    assert {:error, %{reason: :metadata_http_error, data: %{status: 302}}} = Authorization.discover(ctx.url, ctx.opts)
  end

  test "does not reuse a challenge from a different MCP resource", ctx do
    challenge = Challenge.from_response(ctx.origin <> "/other", 401, [])

    assert {:error, %{reason: :challenge_resource_mismatch}} =
             Authorization.discover(ctx.url, Keyword.put(ctx.opts, :challenge, challenge))
  end

  test "preserves escaped quote characters in the challenge", ctx do
    raw = ~S(Bearer error_description="say \"hello\"", scope="read")
    challenge = Challenge.from_response(ctx.url, 401, [{"www-authenticate", raw}])
    assert challenge.error_description == ~s(say "hello")
  end

  test "rejects ambiguous Bearer challenges before fetching", ctx do
    raw = ~s(Bearer resource_metadata="#{ctx.origin}/a", Bearer resource_metadata="#{ctx.origin}/b")
    challenge = Challenge.from_response(ctx.url, 401, [{"www-authenticate", raw}])

    assert {:error, %{reason: :ambiguous_bearer_challenge}} =
             Authorization.discover(ctx.url, Keyword.put(ctx.opts, :challenge, challenge))
  end

  test "rejects duplicate Bearer parameters", ctx do
    challenge = Challenge.from_response(ctx.url, 401, [{"www-authenticate", ~s(Bearer scope="read", scope="write")}])

    assert {:error, %{reason: :invalid_bearer_challenge}} =
             Authorization.discover(ctx.url, Keyword.put(ctx.opts, :challenge, challenge))
  end

  test "preserves a bare 401 while using well-known discovery", ctx do
    resource(ctx, "/.well-known/oauth-protected-resource/mcp")
    issuer(ctx, "/.well-known/oauth-authorization-server/tenant")
    challenge = Challenge.from_response(ctx.url, 401, [])
    assert {:ok, metadata} = Authorization.discover(ctx.url, Keyword.put(ctx.opts, :challenge, challenge))
    assert metadata.challenge.status == 401
  end

  test "does not fall back when the explicit challenge URL is missing", ctx do
    challenge =
      Challenge.from_response(ctx.url, 401, [{"www-authenticate", ~s(Bearer resource_metadata="#{ctx.origin}/missing")}])

    missing(ctx, "/missing")

    assert {:error, %{reason: :metadata_not_found}} =
             Authorization.discover(ctx.url, Keyword.put(ctx.opts, :challenge, challenge))
  end

  test "selects an explicitly requested advertised issuer", ctx do
    resource(ctx, "/.well-known/oauth-protected-resource/mcp", %{
      "authorization_servers" => ["https://unused.example", ctx.origin <> "/tenant"]
    })

    issuer(ctx, "/.well-known/oauth-authorization-server/tenant")
    opts = Keyword.put(ctx.opts, :authorization_server, ctx.origin <> "/tenant")
    assert {:ok, metadata} = Authorization.discover(ctx.url, opts)
    assert metadata.authorization_server == ctx.origin <> "/tenant"
  end

  test "supports trailing slashes in the issuer identifier", ctx do
    resource(ctx, "/.well-known/oauth-protected-resource/mcp", %{"authorization_servers" => [ctx.origin <> "/tenant/"]})
    issuer(ctx, "/.well-known/oauth-authorization-server/tenant", %{"issuer" => ctx.origin <> "/tenant/"})
    assert {:ok, metadata} = Authorization.discover(ctx.url, ctx.opts)
    assert metadata.authorization_server == ctx.origin <> "/tenant/"
  end

  test "root endpoints do not make duplicate metadata requests", ctx do
    ctx = %{ctx | url: ctx.origin}
    missing(ctx, "/.well-known/oauth-protected-resource")
    assert {:error, %{reason: :metadata_not_found}} = Authorization.discover(ctx.url, ctx.opts)
  end

  test "validates authorization endpoint URLs", ctx do
    resource(ctx, "/.well-known/oauth-protected-resource/mcp")
    issuer(ctx, "/.well-known/oauth-authorization-server/tenant", %{"token_endpoint" => "http://insecure.example/token"})
    assert {:error, %{reason: :invalid_discovery_url}} = Authorization.discover(ctx.url, ctx.opts)
  end

  test "validates authorization metadata field types", ctx do
    resource(ctx, "/.well-known/oauth-protected-resource/mcp")
    issuer(ctx, "/.well-known/oauth-authorization-server/tenant", %{"code_challenge_methods_supported" => "S256"})
    assert {:error, %{reason: :invalid_authorization_metadata}} = Authorization.discover(ctx.url, ctx.opts)
  end

  test "caps metadata response size", ctx do
    Bypass.expect_once(ctx.bypass, "GET", "/.well-known/oauth-protected-resource/mcp", fn conn ->
      Plug.Conn.resp(conn, 200, String.duplicate("x", 1_048_577))
    end)

    assert {:error, %{reason: :metadata_too_large}} = Authorization.discover(ctx.url, ctx.opts)
  end

  test "returns a structured error when the metadata server is unreachable", ctx do
    Bypass.down(ctx.bypass)
    assert {:error, %{reason: :metadata_request_failed}} = Authorization.discover(ctx.url, ctx.opts)
  end

  test "preserves a resource query when requesting its well-known metadata", ctx do
    ctx = %{ctx | url: ctx.url <> "?tenant=one"}

    Bypass.expect_once(ctx.bypass, "GET", "/.well-known/oauth-protected-resource/mcp", fn conn ->
      assert conn.query_string == "tenant=one"
      body = %{"resource" => ctx.url, "authorization_servers" => [ctx.origin <> "/tenant"]}
      Plug.Conn.resp(conn, 200, JSON.encode!(body))
    end)

    issuer(ctx, "/.well-known/oauth-authorization-server/tenant")
    assert {:ok, metadata} = Authorization.discover(ctx.url, ctx.opts)
    assert metadata.resource == ctx.url
    assert metadata.resource_metadata_uri == ctx.origin <> "/.well-known/oauth-protected-resource/mcp?tenant=one"
  end

  test "ignores empty HTTP authentication list elements", ctx do
    for raw <- [
          ~s(, Bearer resource_metadata="#{ctx.origin}/metadata",),
          ~s(Bearer resource_metadata="#{ctx.origin}/metadata",,scope="read")
        ] do
      challenge = Challenge.from_response(ctx.url, 401, [{"www-authenticate", raw}])
      assert challenge.parse_error == nil
      assert challenge.resource_metadata == ctx.origin <> "/metadata"
    end
  end

  defp resource(ctx, path, overrides \\ %{}) do
    json(
      ctx,
      path,
      Map.merge(
        %{
          "resource" => ctx.url,
          "authorization_servers" => [ctx.origin <> "/tenant"],
          "scopes_supported" => ["read", "write"]
        },
        overrides
      )
    )
  end

  defp issuer(ctx, path, overrides \\ %{}) do
    json(
      ctx,
      path,
      Map.merge(
        %{
          "issuer" => ctx.origin <> "/tenant",
          "authorization_endpoint" => ctx.origin <> "/authorize",
          "token_endpoint" => ctx.origin <> "/token",
          "response_types_supported" => ["code"],
          "code_challenge_methods_supported" => ["S256"]
        },
        overrides
      )
    )
  end

  defp json(ctx, path, body) do
    Bypass.expect_once(ctx.bypass, "GET", path, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      conn |> Plug.Conn.put_resp_header("content-type", "application/json") |> Plug.Conn.resp(200, JSON.encode!(body))
    end)
  end

  defp missing(ctx, path) do
    Bypass.expect_once(ctx.bypass, "GET", path, &Plug.Conn.resp(&1, 404, ""))
  end
end
