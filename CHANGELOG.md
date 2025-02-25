# Changelog

All notable changes to this project are documented in this file.

## [0.1.0](https://github.com/cloudwalk/hermes-mcp) - 2025-02-26

### Added
- Implemented STDIO transport (#1) for MCP communication
  - Support for bidirectional communication via standard I/O
  - Automatic process monitoring and recovery
  - Environment variable handling for cross-platform support
  - Integration test utilities in Mix tasks

- Created stateful client interface (#6)
  - Robust GenServer implementation for MCP client
  - Automatic initialization and protocol handshake
  - Synchronous-feeling API over asynchronous transport
  - Support for all MCP operations (ping, resources, prompts, tools)
  - Proper error handling and logging
  - Capability negotiation and management

- Developed JSON-RPC message parsing (#5)
  - Schema-based validation of MCP messages
  - Support for requests, responses, notifications, and errors
  - Comprehensive test suite for message handling
  - Encoding/decoding functions with proper validation

- Established core architecture and client API
  - MCP protocol implementation following specification
  - Client struct for maintaining connection state
  - Request/response correlation with unique IDs
  - Initial transport abstraction layer

### Documentation
- Added detailed RFC document describing the library architecture
- Enhanced README with project overview and installation instructions
