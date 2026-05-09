# Authorization

Anubis supports OAuth 2.1 bearer token authorization for HTTP-based transports (`:streamable_http` and `:sse`). STDIO transport is exempt per the MCP specification.

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

```
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

Callers missing required scopes receive a `403 Forbidden` MCP error and a `WWW-Authenticate: Bearer error="insufficient_scope"` header.

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

The server automatically serves the RFC 9728 metadata document at:

```
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

You can also mount `Anubis.Server.Authorization.WellKnown` directly in a Phoenix router if you prefer to handle the route at the application level.

## Standards

| Standard | Coverage |
|---|---|
| RFC 6750 | Bearer token usage on `Authorization` header |
| RFC 9728 | Protected Resource Metadata (`/.well-known/oauth-protected-resource`) |
| RFC 8707 | Audience validation (`aud` claim against `resource` URI) |
| RFC 7662 | Token Introspection |
| RFC 7519 + 7517 | JWT + JWKS verification |

Client-side OAuth flows (PKCE, discovery, token store, refresh) are out of scope — use a dedicated OAuth client library for those.
