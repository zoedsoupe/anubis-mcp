# Extending Anubis

Anubis is a protocol framework, not a closed application. Almost every seam is an `@behaviour` you can implement, and every adapter is selected by option, so swapping one never requires patching another.

This page lists the extension points, what each one is for, and how it gets wired. It is a map, not a tutorial: the guides linked per section carry the examples.

## Server components

Tools, prompts and resources are the units users actually see. Each is a module using `Anubis.Server.Component`, which injects the callbacks for the type you name.

| Behaviour | Implements | Notes |
| --- | --- | --- |
| `Anubis.Server.Component.Tool` | `use Anubis.Server.Component, type: :tool` | `execute/2`, compiled `schema`/`output_schema`, `:task_support` |
| `Anubis.Server.Component.Prompt` | `use Anubis.Server.Component, type: :prompt` | `get_messages/2`, argument schema |
| `Anubis.Server.Component.Resource` | `use Anubis.Server.Component, type: :resource` | `read/2`, `:uri` or `:uri_template`, `:mime_type` |

Schemas are Peri schemas, compiled at build time into the JSON Schema advertised to clients and reused for argument validation. See [Building a Server](building-a-server.md).

## Client transports

A client transport is a GenServer that owns the wire. Implement `Anubis.Transport.Behaviour`:

```elixir
defmodule MyApp.Transport.WebSocket do
  use GenServer
  @behaviour Anubis.Transport.Behaviour

  @impl true
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def send_message(pid, message, opts), do: GenServer.call(pid, {:send, message}, opts[:timeout])

  @impl true
  def shutdown(pid), do: GenServer.stop(pid)

  @impl true
  def supported_protocol_versions, do: ["2025-06-18", "2025-11-25"]
end
```

Three callbacks are required (`start_link/1`, `send_message/3`, `shutdown/1`, `supported_protocol_versions/0`). Four are optional and only used if exported: `transport_init/1`, `parse/2`, `encode/2` and `extract_metadata/2`. They exist for transports that own parse state (newline-delimited JSON, SSE chunks, HTTP bodies); leave them out if you always hand the client fully-decoded messages.

See [Transports](transports.md).

## Server transports

Server transports are selected by `transport:` on `use Anubis.Server`. The shipped ones are `:stdio` and `:streamable_http`. A transport never touches session internals: it resolves a session reference and delegates through `Anubis.Server.Transport.Session`. Implement that instead of reaching into `Anubis.Server.Session`.

## Session dispatch

`Anubis.Server.Transport.Session` is the contract between a transport and the session process. The default (`…Session.Local`) uses `GenServer.call/2` and `cast/2`. Swap it when sessions live on another node, or when the reply shape needs to differ:

```elixir
config :anubis_mcp, :session_dispatcher, MyApp.ClusterDispatcher
```

The wire shapes (`{:mcp_request, message, context}` and friends) are part of the contract, so a custom dispatcher can change the *delivery* without breaking the session.

## Session registry

`Anubis.Server.Registry` maps session ids to processes. STDIO defaults to `Registry.None` (one session, no lookup needed); HTTP defaults to `Registry.Local`. Pass a `{module, opts}` pair to choose your own:

```elixir
use Anubis.Server, transport: :streamable_http, registry: {MyApp.RedixRegistry, pool: 10}
```

The registry also owns deterministic session naming, so it must resolve the same id to the same name on every node.

## Persistence adapters

| Behaviour | Option | Purpose |
| --- | --- | --- |
| `Anubis.Server.Session.Store` | `:session_store` (app env) | Persist session state across server restarts |
| `Anubis.Server.TaskStore` | `task_store: {module, opts}` | Back `Anubis.Server.Task` entries with Redis, ETS, a database |
| `Anubis.Server.Transport.StreamableHTTP.EventStore` | `event_store: {module, opts}` | Record SSE events so a dropped stream can resume from a `Last-Event-ID` |

The session store is configured globally because it starts the adapter process under the server supervisor:

```elixir
config :anubis_mcp, session_store: [enabled: true, adapter: MyApp.RedixSessionStore, ttl: :timer.minutes(30)]
```

Task and event stores are per-server, so two servers in the same application can use different backends.

## Authorization

`Anubis.Server.Authorization.Validator` decides whether a bearer token is acceptable. The bundled `JWTValidator` verifies against a JWKS URI; anything else (introspection, a session table, an mTLS identity) is a module implementing `validate/2`:

```elixir
use Anubis.Server,
  transport: :streamable_http,
  authorization: [
    authorization_servers: ["https://auth.example.com"],
    resource: "https://api.example.com",
    validator: {MyApp.IntrospectionValidator, endpoint: "https://auth.example.com/introspect"}
  ]
```

Authorization only applies to HTTP transports, per the MCP specification. Scopes are enforced separately — see [Authorization](authorization.md).

## Protocol dialects

Each supported MCP version has a module implementing `Anubis.Protocol.Behaviour`, holding the version-specific logic (which methods exist, which capabilities they imply, how requests are shaped). `Anubis.Protocol.Registry` picks one during the `initialize` handshake. To track a version that Anubis does not ship yet, implement the behaviour and register the module.

## Telemetry

Not a behaviour, but the observability seam: every event is namespaced under `[:anubis_mcp, …]` and listed in `Anubis.Telemetry`. Tool calls are spans, so `:start`/`:stop`/`:exception` all fire. Payloads are opt-in — set `:telemetry_capture_tool_payload` only when you are willing to log arguments and results.
