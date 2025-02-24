# Hermes MCP

A high-performance Model Context Protocol (MCP) implementation in Elixir with first-class Phoenix support.

## Overview

Hermes MCP provides a unified solution for building both MCP clients and servers in Elixir, leveraging the language's exceptional concurrency model and fault tolerance capabilities. The library offers seamless integration with Phoenix for HTTP/SSE transport while maintaining support for standard stdio communication.

## Features

The library implements the full [Model Context Protocol specification](https://spec.modelcontextprotocol.io/specification/2024-11-05/), providing:

- Complete client and server implementations with protocol lifecycle management 
- First-class Phoenix integration for HTTP/SSE transport
- Robust stdio transport for local process communication
- Built-in connection supervision and automatic recovery
- Comprehensive capability negotiation

## Installation

Add Hermes MCP to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:hermes_mcp, "~> 0.1.0"}
  ]
end
```

## Architecture

The library is structured around several core components:

- Protocol Layer: Handles message framing, request/response correlation, and lifecycle management
- Transport Layer: Provides pluggable transports for stdio and HTTP/SSE communication
- Server Components: Implements server-side protocol operations with Phoenix integration
- Client Components: Manages client-side operations and capability negotiation
- Supervision Trees: Ensures fault tolerance and automatic recovery

Check out our technical [RFC](rfc.md) that describe each component more in deep.

## Development Status

Hermes MCP is currently under active development. The initial release will focus on providing stable protocol implementation focused into client interface to existing MCP servers. The API is subject to change as we refine the design based on real-world usage patterns.

We encourage you to star the repository and watch for updates as we progress toward our first stable release.

## Contributing

We welcome contributions to Hermes MCP! The project is in its early stages, and we're particularly interested in feedback on the design and architecture. Please check our [Issues](https://github.com/cloudwalk/hermes-mcp/issues) page for ways to contribute.

## License

Hermes MCP is released under the MIT License. See [LICENSE](LICENSE) for details.

## Why Hermes?

The library is named after Hermes, the Greek god of boundaries, communication, and commerce. This namesake reflects the core purpose of the Model Context Protocol: to establish standardized communication between AI applications and external tools. Like Hermes who served as a messenger between gods and mortals, this library facilitates seamless interaction between Large Language Models and various data sources or tools.

Furthermore, Hermes was known for his speed and reliability in delivering messages, which aligns with our implementation's focus on high performance and fault tolerance in the Elixir ecosystem. The name also draws inspiration from the Hermetic tradition of bridging different domains of knowledge, much like how MCP bridges the gap between AI models and external capabilities.
