# Transports

MCP separates what a server offers from how the bytes move. Anubis ships two transports you will actually deploy, STDIO and Streamable HTTP, plus two legacy ones kept for compatibility. This guide covers each from both the server and the client side.

## Choosing a transport

**STDIO** runs the server as a subprocess of the client and speaks newline-delimited JSON over standard input and output. It is the default for local tooling: editor integrations, CLI assistants, one machine, one user. There is no network listener and no authentication surface.

**Streamable HTTP** exposes the server as an HTTP endpoint. Requests arrive as POSTs and the server can push notifications over an SSE stream on the same path. Pick it whenever clients connect over the network, when multiple clients share one server, or when the server lives inside an existing web application. This is the transport the current MCP specification recommends for remote servers.

**WebSocket** (client only) and **HTTP+SSE** (the pre-2025 two-endpoint scheme) remain for talking to older servers. Do not build anything new on them.

## STDIO

### Serving over STDIO

```elixir
children = [
  {MyApp.Server, transport: :stdio}
]
```

The process reads requests from stdin and writes responses to stdout. That has one practical consequence: anything else your application prints to stdout corrupts the protocol stream. Keep `Logger` output on stderr in STDIO servers:

```elixir
# config/config.exs
config :logger, :default_handler, config: [type: :standard_error]
```

A convenient way to package a STDIO server is a plain script with `Mix.install`, which any MCP client can spawn:

```bash
claude mcp add my-app -- elixir --no-halt my_app.exs
```

### Connecting over STDIO

```elixir
{Anubis.Client,
 name: MyApp.MCPClient,
 transport: {:stdio, command: "python", args: ["-m", "my_server"]},
 client_info: %{"name" => "MyApp", "version" => "1.0.0"},
 capabilities: %{}}
```

The client spawns the command as a subprocess and supervises it alongside the connection. Beyond `command` and `args` you can pass `env`, a map merged over a safe default environment, and `cwd` to set the working directory.

## Streamable HTTP

### Serving over HTTP

The server process and the HTTP endpoint are separate pieces. The server supervisor manages sessions and notification streams; a plug, `Anubis.Server.Transport.StreamableHTTP.Plug`, turns HTTP requests into protocol messages. You start the first and mount the second wherever your HTTP stack lives.

In a Phoenix application:

```elixir
# lib/my_app_web/router.ex
forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug, server: MyApp.Server

# in your supervision tree
children = [
  MyAppWeb.Endpoint,
  {MyApp.Server, transport: :streamable_http}
]
```

In a plain `Plug.Router`:

```elixir
forward "/mcp",
  to: Anubis.Server.Transport.StreamableHTTP.Plug,
  init_opts: [server: MyApp.Server]
```

Standalone, with Bandit serving nothing but MCP:

```elixir
children = [
  {MyApp.Server, transport: :streamable_http},
  {Bandit, plug: {Anubis.Server.Transport.StreamableHTTP.Plug, server: MyApp.Server}, port: 8080}
]
```

The plug accepts a few options besides `server`:

- `:session_header` renames the session id header, which defaults to `mcp-session-id`.
- `:request_timeout` bounds each request, defaulting to 30 seconds.
- `:subscriber_metadata` takes a function from `Plug.Conn` to a map, letting you tag SSE subscribers with data derived from the request, such as a tenant id.

### Sessions

Each connecting client gets its own session process, identified by the session id header the server assigns during initialization. Sessions hold the frame state described in [Building a Server](building-a-server.md) and expire after 30 minutes idle by default. Tune that with `session_idle_timeout`:

```elixir
{MyApp.Server,
 transport: :streamable_http,
 session_idle_timeout: to_timeout(minute: 10)}
```

### Conditional startup

When running inside a Phoenix release, the HTTP-transport server follows the endpoint's lead: it starts only when Phoenix is serving requests, so nodes started for a migration or a remote console do not spin up MCP sessions. Outside Phoenix it starts unconditionally. To override the detection, pass `start:` explicitly:

```elixir
{MyApp.Server, transport: {:streamable_http, start: true}}
```

The `ANUBIS_MCP_SERVER` environment variable forces startup as well, mirroring how `PHX_SERVER` works for Phoenix.

### Connecting over HTTP

```elixir
{Anubis.Client,
 name: MyApp.MCPClient,
 transport: {:streamable_http, base_url: "https://api.example.com"},
 client_info: %{"name" => "MyApp", "version" => "1.0.0"},
 capabilities: %{}}
```

The endpoint path defaults to `/mcp`; set `mcp_path:` to change it. Pass `headers:` for anything the server requires, such as a bearer token:

```elixir
transport: {:streamable_http,
  base_url: "https://api.example.com",
  mcp_path: "/ai/mcp",
  headers: %{"authorization" => "Bearer #{token}"}}
```

## Legacy transports

The HTTP+SSE transport from protocol version 2024-11-05 used one endpoint for the event stream and another for posting messages. Anubis still speaks it on both sides: clients via `transport: {:sse, base_url: ...}`, servers via `Anubis.Server.Transport.SSE.Plug`. The WebSocket client transport, `transport: {:websocket, base_url: ...}`, connects to servers that offer it. Both exist so you can talk to deployments that have not migrated; prefer Streamable HTTP everywhere you control.

## Next steps

- [Authorization](authorization.md) secures HTTP transports with OAuth 2.1 bearer tokens.
- [Building a Server](building-a-server.md) and [Building a Client](building-a-client.md) cover what runs on top of the transport.
