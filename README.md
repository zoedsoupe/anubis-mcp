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
    {:anubis_mcp, "~> 0.17.0"}  # x-release-please-version
  ]
end
```

## Quick Start

### Server

```elixir
# Define a server with tools capabilities
defmodule MyApp.MCPServer do
  use Anubis.Server,
    name: "My Server",
    version: "1.0.0",
    capabilities: [:tools]

  @impl true
  # this callback will be called when the
  # MCP initialize lifecycle completes
  def init(_client_info, frame) do
    {:ok,frame
      |> assign(counter: 0)
      |> register_tool("echo",
        input_schema: %{
          text: {:required, :string, max: 150, description: "the text to be echoed"}
        },
        annotations: %{read_only: true},
        description: "echoes everything the user says to the LLM") }
  end

  @impl true
  def handle_tool("echo", %{text: text}, frame) do
    Logger.info("This tool was called #{frame.assigns.counter + 1}")
    {:reply, text, assign(frame, counter: frame.assigns.counter + 1)}
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
# Define a client module
defmodule MyApp.MCPClient do
  use Anubis.Client,
    name: "MyApp",
    version: "1.0.0",
    protocol_version: "2025-03-26"
end

# Add to your application supervisor
children = [
  {MyApp.MCPClient,
   transport: {:streamable_http, base_url: "http://localhost:4000"}}
]

# Use the client
{:ok, result} = MyApp.MCPClient.call_tool("echo", %{text: "this will be echoed!"})
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
