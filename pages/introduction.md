# Introduction

Anubis is an Elixir implementation of the [Model Context Protocol](https://modelcontextprotocol.io/), covering both sides of the wire. You can build MCP servers that expose tools, resources, and prompts from your application, and MCP clients that connect your application to servers written in any language.

## What is MCP?

MCP is an open protocol that standardizes how AI applications talk to external systems. A server exposes capabilities in three forms:

- **Tools** are functions a model can call, such as a search or a database lookup.
- **Resources** are data a model can read, such as files or configuration.
- **Prompts** are reusable message templates the client can fetch and fill in.

A client connects to a server, negotiates a protocol version and capabilities during an initialization handshake, and then invokes whatever the server offers. The protocol is JSON-RPC 2.0 over a transport, usually a subprocess speaking on STDIO or an HTTP endpoint.

Anubis handles the protocol layer for you: message encoding, version negotiation, capability discovery, request tracking, timeouts, and error reporting. Servers and clients run as supervised OTP processes.

## Installation

Add the dependency to your `mix.exs`:

```elixir
def deps do
  [
    {:anubis_mcp, "~> 1.10.0"} # x-release-please-version
  ]
end
```

Anubis requires Elixir 1.15 or later.

## A minimal server

A server is a module that declares its identity and capabilities, plus one module per component. Here is a complete server with a single tool:

```elixir
defmodule MyApp.Greeter do
  @moduledoc "Greet a person by name"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :name, :string, required: true
  end

  @impl true
  def execute(%{name: name}, frame) do
    {:reply, Response.text(Response.tool(), "Hello, #{name}!"), frame}
  end
end

defmodule MyApp.Server do
  use Anubis.Server,
    name: "my-app",
    version: "1.0.0",
    capabilities: [:tools]

  component MyApp.Greeter
end
```

Add it to your supervision tree with a transport:

```elixir
children = [
  {MyApp.Server, transport: :stdio}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The `@moduledoc` becomes the tool description, the `schema` block becomes its JSON Schema, and any client that connects can now discover and call `greeter`. To try it against a real client, save the modules together with a `Mix.install` header in a script and register it:

```bash
claude mcp add my-app -- elixir --no-halt my_app.exs
```

The [Building a Server](building-a-server.md) guide walks through tools, resources, prompts, and server state in detail.

## A minimal client

A client is a supervised process that owns one connection to one server:

```elixir
children = [
  {Anubis.Client,
   name: MyApp.MCPClient,
   transport: {:stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-everything"]},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   capabilities: %{}}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Once started, the client negotiates the handshake on its own. You interact with it by name:

```elixir
{:ok, response} = Anubis.Client.list_tools(MyApp.MCPClient)

{:ok, response} =
  Anubis.Client.call_tool(MyApp.MCPClient, "echo", %{"message" => "hello"})
```

The [Building a Client](building-a-client.md) guide covers discovery, error handling, progress tracking, and managing several connections.

## Where to go next

- [Building a Server](building-a-server.md) covers components, responses, and server state.
- [Building a Client](building-a-client.md) covers connecting to and consuming servers.
- [Transports](transports.md) explains STDIO and Streamable HTTP, including Phoenix integration.
- [Authorization](authorization.md) documents OAuth 2.1 bearer token support for HTTP servers.
- [Testing](testing.md) shows how to test your components with plain ExUnit.
- [Recipes](recipes.md) collects patterns for common production concerns.
