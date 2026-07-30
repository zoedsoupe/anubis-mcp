defmodule Anubis.Protocol.Behaviour do
  @moduledoc """
  Dialect contract that each MCP protocol version module must implement.

  Each protocol version (e.g., 2025-03-26, 2025-06-18, 2025-11-25) implements
  this behaviour to isolate version-specific logic. A version module owns
  everything about its version: params and result schemas, full message
  schemas, capability shaping, feature flags, transport rules, and the era
  the version belongs to. Adding or removing a version means adding or
  removing one module plus one entry in `Anubis.Protocol.Registry`.

  ## Eras

  Versions group into eras with structurally different session semantics:

    * `:legacy` — session-oriented versions with the `initialize` handshake
      (all versions up to and including 2025-11-25)
    * `:stateless` — per-request versions without protocol-level sessions
      (2026-07-28 onward)

  ## Version differences

  - **2025-03-26**: Streamable HTTP, JSON-RPC batching, authorization framework, tool annotations (support floor)
  - **2025-06-18**: Removed batching, added structured tool output, elicitation, resource_link type
  - **2025-11-25**: Added tasks (`tasks/get`, `tasks/result`, `tasks/list`, `tasks/cancel`)
  """

  @type version :: String.t()
  @type method :: String.t()
  @type params :: map()
  @type message :: map()
  @type feature :: atom()
  @type era :: :legacy | :stateless

  @typedoc """
  Transport-level rules that vary per protocol version.

    * `:batching` — whether JSON-RPC batch arrays are part of the version
    * `:protocol_version_header` — whether HTTP clients MUST send the
      negotiated version on the `MCP-Protocol-Version` header after initialize
  """
  @type transport_rules :: %{batching: boolean(), protocol_version_header: boolean()}

  @doc "Returns the era this version belongs to (`:legacy` or `:stateless`)."
  @callback era() :: era()

  @doc "Returns the version string this module implements (e.g., '2025-03-26')."
  @callback version() :: version()

  @doc "List of features/capabilities this protocol version supports."
  @callback supported_features() :: [feature()]

  @doc "Checks if a feature is supported by this protocol version."
  @callback supports_feature?(feature()) :: boolean()

  @doc "Transport-level rules in effect for this protocol version."
  @callback transport_rules() :: transport_rules()

  @doc """
  Shapes a server's declared capabilities for advertisement in this version.

  Takes the capabilities map declared by the server module and returns the
  subset this protocol version can advertise. Capabilities introduced by
  later versions are dropped so a negotiated session never advertises
  features its version does not model.
  """
  @callback server_capabilities(map()) :: map()

  @doc "Peri schema for validating request params by method for this version."
  @callback request_params_schema(method()) :: term()

  @doc "Peri schema for validating notification params by method for this version."
  @callback notification_params_schema(method()) :: term()

  @doc """
  Peri schema for validating a request's result by method for this version.

  Returns `nil` for methods whose result this version does not model;
  callers fall back to accepting any result.
  """
  @callback request_result_schema(method()) :: term() | nil

  @doc "Progress notification params schema for this version."
  @callback progress_params_schema() :: map()

  @doc "All request methods supported by this version."
  @callback request_methods() :: [method()]

  @doc "All notification methods supported by this version."
  @callback notification_methods() :: [method()]

  @doc """
  Full `{:multi, :method, branches}` Peri schema for request messages.

  Includes the JSON-RPC envelope (jsonrpc, method, params, id) around each
  method's params schema. This is the single source of truth for request
  validation and encoding in this version.
  """
  @callback request_message_schema() :: term()

  @doc """
  Full `{:multi, :method, branches}` Peri schema for notification messages.

  Includes the JSON-RPC envelope (jsonrpc, method, params) around each
  method's params schema.
  """
  @callback notification_message_schema() :: term()
end
