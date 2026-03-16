# Anubis MCP

[![hex.pm](https://img.shields.io/hexpm/v/anubis_mcp.svg)](https://hex.pm/packages/anubis_mcp)
[![docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/anubis_mcp)
[![ci](https://github.com/zoedsoupe/anubis-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/zoedsoupe/anubis-mcp/actions/workflows/ci.yml)
[![Hex Downloads](https://img.shields.io/hexpm/dt/anubis_mcp)](https://hex.pm/packages/anubis_mcp)

A high-performance Model Context Protocol (MCP) implementation in Elixir.

## Overview

Anubis MCP is a comprehensive Elixir SDK for the [Model Context Protocol](https://spec.modelcontextprotocol.io/), providing complete client and server implementations with Elixir's exceptional concurrency model and fault tolerance.

## Installation

```elixir
def deps do
  [
    {:anubis_mcp, "~> 1.0.0"}  # x-release-please-version
  ]
end
```

## Quick Start

### Server

```elixir
# Define a tool as a Component (compile-time registration)
defmodule MyApp.Echo do
  @moduledoc "Echoes everything the user says to the LLM"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :text, :string, required: true, max_length: 150, description: "the text to be echoed"
  end

  @impl true
  def execute(%{text: text}, frame) do
    {:reply, Response.text(Response.tool(), text), frame}
  end
end

defmodule MyApp.MCPServer do
  use Anubis.Server,
    name: "My Server",
    version: "1.0.0",
    capabilities: [:tools]

  # Static component registration — dispatches to MyApp.Echo.execute/2
  component MyApp.Echo

  @impl true
  def init(_client_info, frame) do
    # You can also register tools dynamically at runtime via the Frame:
    # frame = register_tool(frame, "dynamic_tool", description: "...", input_schema: %{...})
    {:ok, frame}
  end
end

# Add to your application supervisor
children = [
  Anubis.Server.Registry,
  {MyApp.MCPServer, transport: :streamable_http}
]

# Add to your Phoenix router (if using HTTP)
forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug, server: MyApp.MCPServer

# Or if using only Plug router
forward "/mcp", to: Anubis.Server.Transport.StreamableHTTP.Plug, init_opts: [server: MyApp.MCPServer]
```

Now you can achieve your MCP server on `http://localhost:<port>/mcp`

### Client

```elixir
# Add to your application supervisor
children = [
  {Anubis.Client,
   name: MyApp.MCPClient,
   transport: {:streamable_http, base_url: "http://localhost:4000"},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   protocol_version: "2025-06-18"}
]

# Use the client
{:ok, result} = Anubis.Client.call_tool(MyApp.MCPClient, "echo", %{text: "this will be echoed!"})
```

## Why Anubis?

Named after Anubis, the Egyptian god of the underworld and guide to the afterlife, this library helps navigate the boundaries between Large Language Models and external tools. Much like how Anubis guided souls through transitions, this SDK guides data through the liminal space between AI and external systems.

The name also carries personal significance - after my journey through the corporate underworld ended unexpectedly, this project was reborn from the ashes of its predecessor, ready to guide developers through their own MCP adventures. Sometimes you need a deity of transitions to help you... transition. 🏳️‍⚧️

## Sponsors

Thanks to our amazing sponsors for supporting this project!

<p align="center">
  <a href="https://www.coderabbit.ai/?utm_source=oss&utm_medium=github&utm_campaign=zoedsoupe">
    <img src="https://avatars.githubusercontent.com/u/132028505?s=200&v=4" alt="Coderabbit Sponsor Logo" height="80"/>
  </a>
</p>

## Documentation

For detailed guides and examples, visit the [official documentation](https://hexdocs.pm/anubis_mcp).

## Examples

We have build some elixir implementation examples using `plug` based and `phoenix` apps:

1. [upcase-server](/priv/dev/upcase/README.md): `plug` based MCP server using streamable_http
2. [echo-elixir](/priv/dev/echo-elixir/README.md): `phoenix` based MCP server using sse
3. [ascii-server](/priv/dev/ascii/README.md): `phoenix_live_view` based MCP server using streamable_http and UI

## License

LGPL-v3 License. See [LICENSE](./LICENSE) for details.
