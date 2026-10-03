# Transports

MCP separates what a server offers from how the bytes move. Anubis ships two transports, STDIO and Streamable HTTP. This guide covers each from both the server and the client side.

## Choosing a transport

**STDIO** runs the server as a subprocess of the client and speaks newline-delimited JSON over standard input and output. It is the default for local tooling: editor integrations, CLI assistants, one machine, one user. There is no network listener and no authentication surface.

**Streamable HTTP** exposes the server as an HTTP endpoint. Requests arrive as POSTs and the server can push notifications over an SSE stream on the same path. Pick it whenever clients connect over the network, when multiple clients share one server, or when the server lives inside an existing web application. This is the transport the current MCP specification recommends for remote servers.

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

### Stateless requests (2026-07-28)

Protocol revision 2026-07-28 drops the `initialize` handshake and the session: every request carries its protocol version, client info and capabilities in `params._meta`. The plug serves it once the server declares it, next to the handshake versions it keeps serving:

```elixir
use Anubis.Server,
  name: "my-server",
  version: "1.0.0",
  capabilities: [:tools],
  protocol_versions: ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]
```

The `MCP-Protocol-Version` header picks the era for each request. Without it, or with a handshake version, requests use the legacy session path. A body declaring a stateless protocol version on that path is rejected with HTTP 400 and `-32020` before the session is accessed. With `2026-07-28`:

- `Mcp-Method` must name the body's method, and `Mcp-Name` the tool, prompt or resource for `tools/call`, `prompts/get` and `resources/read`; a mismatch, or a `_meta` version different from the header, is a 400 with `-32020`.
- The request is served by a session started for it alone and stopped once it answers. `init/2` runs for it with that request's client info, and the frame does not carry over to the next request. The `[:server, :init]` and `[:server, :terminate]` telemetry events fire once per such request.
- No `mcp-session-id` is read or sent, GET and DELETE are 405, and a notification is a 202 with no body.
- A version the server does not declare is a 400 with `-32022` listing the stateless versions it serves. A server that declares none answers as before, so clients that speak both eras fall back to `initialize`.

#### Progress and cancellation

A client that accepts `text/event-stream` may get its answer as a stream. The response turns into SSE once the handler emits a `notifications/progress` for the request (or a `notifications/message`, when the request set a log level), or once the request outlives the transport's keepalive interval; the notifications come in order, and the JSON-RPC response ends the stream. A request answered before either happens is a single JSON object.

If the low-level `handle_request/2` callback completes with `{:noreply, frame}`, the server sends HTTP 202 with an empty body before streaming starts, or closes an already-open SSE response without a final event. It does not turn a successful no-reply completion into a JSON-RPC error.

Closing the response is how a client cancels a request in this revision, and a disconnect is only visible when the server writes. A long request therefore writes a keepalive comment every interval, and the first write that fails stops the request's session, which terminates the handler. With `keepalive: false` on the transport, or a client that accepts only JSON, a disconnect goes unnoticed until the handler returns.

#### Caching hints

The complete results of `server/discover`, `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list` and `resources/read` carry `ttlMs` and `cacheScope`, as the revision requires. They default to `0` and `"private"`: stale at once, and never shared between callers. A server that knows better says so per method:

```elixir
@impl true
def cache_hints("tools/list"), do: %{ttl_ms: to_timeout(minute: 5), scope: :private}
def cache_hints(_method), do: %{ttl_ms: 0, scope: :private}
```

Use `:public` only for a result that is the same for every caller; a list filtered per user is `:private`. An input-required result carries no hints, and the result of a multi round-trip retry is always `ttlMs: 0`.

#### Subscriptions

`subscriptions/listen` answers with an SSE stream that stays open. It opens with `notifications/subscriptions/acknowledged`, naming the part of the client's filter the server honors: a list-changed flag for a capability declared with `list_changed?: true`, and a resource URI when `resources` is declared with `subscribe?: true` and the URI passes the same scope check as `resources/subscribe`. Only those notifications follow, each carrying the subscription id in `_meta`.

The stream is served by a session that lives as long as the stream does and does not expire when idle. `init/2` runs for it once, and the server emits into it the way it does in the handshake era, from its own callbacks: `Notifier.resource_updated/3`, `Notifier.tools_list_changed/1` and the other list-changed helpers, typically from `handle_info/2` after subscribing the session to the application's events in `init/2`. Other notifications, such as log messages, never reach the stream. When the session stops or the transport shuts down, the stream ends with a completion result for the `subscriptions/listen` request.

```elixir
@impl true
def init(_client_info, frame) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "reports:#{frame.assigns.current_user.id}")
  {:ok, frame}
end

@impl true
def handle_info({:report_ready, id}, frame) do
  Notifier.resource_updated(frame, "reports://#{id}")
  {:noreply, frame}
end
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

## Removed transports

The WebSocket client transport was removed in Anubis 2.1. It was never part of the MCP spec; use Streamable HTTP instead.

The HTTP+SSE transport from protocol version 2024-11-05 was removed in Anubis 2.0, together with support for that spec version. Use Streamable HTTP instead.

## Next steps

- [Authorization](authorization.md) secures HTTP transports with OAuth 2.1 bearer tokens.
- [Building a Server](building-a-server.md) and [Building a Client](building-a-client.md) cover what runs on top of the transport.
