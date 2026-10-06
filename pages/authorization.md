# Authorization

Anubis supports OAuth 2.1 bearer token authorization for HTTP-based transports (`:streamable_http`). STDIO transport is exempt per the MCP specification.

## Quick Start

```elixir
defmodule MyApp.MCPServer do
  use Anubis.Server,
    transport: :streamable_http,
    authorization: [
      authorization_servers: ["https://auth.example.com"],
      resource: "https://api.example.com",
      scopes_supported: ["tools:read", "tools:write"],
      validator: {Anubis.Server.Authorization.JWTValidator,
        jwks_uri: "https://auth.example.com/.well-known/jwks.json"}
    ]
end
```

Every request to the server must include a valid bearer token:

```http
Authorization: Bearer <token>
```

Requests without a token or with an invalid token receive a `401 Unauthorized` response with a `WWW-Authenticate` header pointing to the protected resource metadata document.

## Validators

### JWT Validator

Validates signed JWTs by fetching the authorization server's JWKS. Requires the optional `:jose` dependency:

```elixir
{:jose, "~> 1.11"}
```

```elixir
validator: {Anubis.Server.Authorization.JWTValidator,
  jwks_uri: "https://auth.example.com/.well-known/jwks.json",
  issuer: "https://auth.example.com"   # optional iss validation
}
```

JWKS responses are cached in `:persistent_term` for 5 minutes per `jwks_uri`.

### Introspection Validator

Validates tokens via RFC 7662 introspection. Works with any token format:

```elixir
validator: {Anubis.Server.Authorization.IntrospectionValidator,
  introspection_endpoint: "https://auth.example.com/introspect",
  client_id: "my-resource-server",       # optional Basic auth
  client_secret: "my-secret"
}
```

### Custom Validator

Implement `Anubis.Server.Authorization.Validator` for any other token format:

```elixir
defmodule MyApp.TokenValidator do
  @behaviour Anubis.Server.Authorization.Validator

  @impl true
  def validate_token(token, _config) do
    case MyApp.Token.verify(token) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

## Scope Enforcement

Declare required scopes on individual components:

```elixir
defmodule MyApp.WriteFileTool do
  use Anubis.Server.Component, type: :tool, scopes: ["files:write"]

  schema do
    field :path, :string, required: true
    field :content, :string, required: true
  end

  def execute(params, frame) do
    # Only reached when caller has "files:write" scope
    {:reply, Response.text(Response.tool(), "Written"), frame}
  end
end
```

Callers missing required scopes receive an MCP execution error indicating `insufficient_scope` with the required and granted scopes in the error payload.

## Accessing Claims in Handlers

Validated claims are available on the frame:

```elixir
def execute(params, frame) do
  subject = Anubis.Server.Frame.subject(frame)      # "user-123"
  scopes  = Anubis.Server.Frame.scopes(frame)       # ["tools:read", "tools:write"]
  auth    = Anubis.Server.Frame.authorization(frame) # full claims map

  if Anubis.Server.Frame.has_scope?(frame, "admin") do
    # privileged path
  end

  {:reply, Response.text(Response.tool(), "Hello #{subject}"), frame}
end
```

## Protected Resource Metadata

The server serves the RFC 9728 metadata document at:

```http
GET /.well-known/oauth-protected-resource
```

Response:

```json
{
  "resource": "https://api.example.com",
  "authorization_servers": ["https://auth.example.com"],
  "scopes_supported": ["tools:read", "tools:write"],
  "bearer_methods_supported": ["header"]
}
```

The Streamable HTTP plug handles this path inline when it is mounted at the root of the host. If you mount the MCP plug under a sub-path (e.g. `/mcp`), requests to `/.well-known/oauth-protected-resource` never reach the plug. In that case mount `Anubis.Server.Transport.WellKnown` as a sibling route:

```elixir
# Plug.Router
forward "/.well-known/oauth-protected-resource",
  to: Anubis.Server.Transport.WellKnown,
  init_opts: [server: MyApp.MCPServer]

forward "/mcp", to: Anubis.Server.Transport.StreamableHTTP.Plug,
  init_opts: [server: MyApp.MCPServer]
```

```elixir
# Phoenix
forward "/.well-known/oauth-protected-resource",
  Anubis.Server.Transport.WellKnown,
  server: MyApp.MCPServer
```

## Standards

| Standard        | Coverage                                                              |
| --------------- | --------------------------------------------------------------------- |
| RFC 6750        | Bearer token usage on `Authorization` header                          |
| RFC 9728        | Protected Resource Metadata (`/.well-known/oauth-protected-resource`) |
| RFC 8707        | Audience validation (`aud` claim against `resource` URI)              |
| RFC 7662        | Token Introspection                                                   |
| RFC 7519 + 7517 | JWT + JWKS verification                                               |

## Client-side discovery

`Anubis.Client.Authorization.discover/2` discovers the metadata needed by an OAuth client, using the application's existing Finch pool. The URL is the full MCP endpoint, including its path:

```elixir
alias Anubis.Client.Authorization

{:ok, metadata} = Authorization.discover("https://mcp.example.com/api/mcp")

metadata.authorization_endpoint
metadata.token_endpoint
metadata.resource
```

Discovery first requests `/.well-known/oauth-protected-resource/api/mcp`, then the root metadata location if the first returns 404 or 405. It discovers the selected issuer through OAuth authorization server metadata, then the two OIDC locations defined by MCP for issuers with paths. Invalid documents fail validation instead of falling through to another location. Missing metadata is an error, not evidence that the server permits unauthenticated access.

The result is an `Anubis.Client.Authorization.Metadata` struct. Pass its `resource` value in **both authorization and token requests** as required by RFC 8707. Keep using `mcp_url` as the MCP connection URL: a root metadata document may identify a broader resource. `scopes_supported` describes resource scopes; a challenge's `scope` is separate and authoritative for the challenged request.

### Reactive discovery

The HTTP transport preserves `WWW-Authenticate` on a 401, and on a 403 carrying `error="insufficient_scope"`. Direct transport calls return `{:error, {:authorization_required, challenge}}`. Client calls wrap that value in `Anubis.MCP.Error.data.original_reason`; this also works through `await_ready/2` when initialization requires authorization:

```elixir
alias Anubis.Client
alias Anubis.Client.Authorization
alias Anubis.MCP.Error

case Client.await_ready(MyApp.MCPClient) do
  :ok ->
    :ok

  {:error, %Error{data: %{original_reason: {:authorization_required, challenge}}}} ->
    Authorization.discover(challenge.mcp_url, challenge: challenge)
end
```

The challenge retains the original header values, HTTP status, `scope`, `error` and `error_description`. Its `resource_metadata` URL takes precedence over well-known locations. Distinct Bearer challenges are rejected as ambiguous. An authorization failure during initialization leaves the client alive and releases initialization waiters with the error; it does not retry or open a browser. After obtaining a token, the host can restart the client with its normal `Authorization: Bearer ...` transport header.

### Issuer selection and network access

If resource metadata advertises multiple authorization servers, discovery returns an error with reason `:authorization_server_selection_required` and the list in `error.data.authorization_servers`. Select an advertised issuer explicitly:

```elixir
Authorization.discover("https://mcp.example.com/api/mcp",
  authorization_server: "https://auth.example.com/tenant"
)
```

The returned resource and issuer identifiers are checked against the discovery context; endpoint URLs and metadata fields are validated. HTTPS is required. Local development can opt into HTTP on `localhost`, `127.0.0.1` or `::1` with `allow_insecure_localhost: true`.

Metadata requests carry no bearer tokens or other credentials, do not follow redirects, and accept responses up to 1 MiB. Configure `:finch_name` and `:http_options` to use an application-owned pool and timeouts. `:url_policy` accepts a `fn url -> :ok | {:error, reason} end` callback before every metadata fetch. Hosts accepting untrusted MCP URLs must apply their own egress policy, including private-address and DNS-rebinding restrictions; HTTPS and identifier validation alone do not provide SSRF protection.

Consent UI, client registration, PKCE, token storage and refresh remain the responsibility of the host application's OAuth client. Discovery does not acquire tokens or implement the server-side features tracked in #261.
