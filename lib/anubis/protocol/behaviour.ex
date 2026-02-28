defmodule Anubis.Protocol.Behaviour do
  @moduledoc """
  Behaviour that each MCP protocol version module must implement.

  Each protocol version (e.g., 2024-11-05, 2025-03-26, 2025-06-18) implements
  this behaviour to isolate version-specific logic. This makes it trivial to add
  support for new MCP spec versions without scattering conditionals across the codebase.

  ## Version differences

  - **2024-11-05**: Initial spec, SSE transport, basic tools/resources/prompts
  - **2025-03-26**: Added Streamable HTTP, JSON-RPC batching, authorization framework, tool annotations
  - **2025-06-18**: Removed batching, added structured tool output, elicitation, resource_link type
  """

  @type version :: String.t()
  @type method :: String.t()
  @type params :: map()
  @type message :: map()
  @type feature :: atom()

  @doc "Returns the version string this module implements (e.g., '2025-03-26')."
  @callback version() :: version()

  @doc "List of features/capabilities this protocol version supports."
  @callback supported_features() :: [feature()]

  @doc "Peri schema for validating request params by method for this version."
  @callback request_params_schema(method()) :: term()

  @doc "Peri schema for validating notification params by method for this version."
  @callback notification_params_schema(method()) :: term()

  @doc "Progress notification params schema for this version."
  @callback progress_params_schema() :: map()

  @doc "All request methods supported by this version."
  @callback request_methods() :: [method()]

  @doc "All notification methods supported by this version."
  @callback notification_methods() :: [method()]
end
