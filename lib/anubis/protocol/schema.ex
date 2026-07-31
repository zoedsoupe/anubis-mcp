defmodule Anubis.Protocol.Schema do
  @moduledoc """
  Helpers for building JSON-RPC message schemas inside protocol version modules.

  A protocol version owns the full shape of its messages: method names, params
  schemas, and the JSON-RPC envelope around them. These helpers build the
  envelope branches for `{:multi, :method, branches}` schemas and merge the
  `params._meta` slots every version shares, so version modules stay focused
  on what changed between versions.

  The `_meta` slot differs by era. Legacy versions negotiate their metadata
  once and carry only `progressToken` per request (`with_progress_meta/1`);
  stateless versions carry the protocol version, capabilities and identity on
  every request (`with_request_meta/1`).
  """

  @progress_meta %{"_meta" => %{"progressToken" => {:either, {:string, :integer}}}}

  @log_levels ~w(debug info notice warning error critical alert emergency)

  @request_meta %{"_meta" => {:required, {:custom, &__MODULE__.validate_request_meta/1}}}

  @doc """
  Returns the schema fragment for the `params._meta.progressToken` slot
  shared by all MCP requests.
  """
  @spec progress_meta() :: map()
  def progress_meta, do: @progress_meta

  @doc """
  Merges the progress `_meta` slot into a params schema map.

  Non-map schemas (e.g. `:map`) pass through unchanged.
  """
  @spec with_progress_meta(term()) :: term()
  def with_progress_meta(schema) when is_map(schema), do: Map.merge(schema, @progress_meta)
  def with_progress_meta(schema), do: schema

  @doc """
  Returns the log levels defined by the MCP specification, in ascending
  severity (RFC 5424).
  """
  @spec log_levels() :: [String.t()]
  def log_levels, do: @log_levels

  @doc """
  Merges the stateless-era per-request `_meta` slot into a params schema map.

  Versions in the `:stateless` era carry the protocol version, client
  capabilities and optional client identity on every request instead of
  negotiating them once. The slot is validated by
  `validate_request_meta/1` rather than declared as a nested schema, so
  that `_meta` keys this version does not model — extension and
  OpenTelemetry keys — survive validation instead of being stripped.

  Non-map schemas (e.g. `:map`) pass through unchanged.
  """
  @spec with_request_meta(term()) :: term()
  def with_request_meta(schema) when is_map(schema), do: Map.merge(schema, @request_meta)
  def with_request_meta(schema), do: schema

  @doc """
  Validates the reserved `io.modelcontextprotocol/*` keys of a stateless-era
  request's `_meta`, returning the map unchanged so unmodeled keys survive.

  `protocolVersion` and `clientCapabilities` are required on every request;
  `clientInfo` and `logLevel` are optional but validated when present.
  """
  @spec validate_request_meta(term()) :: :ok | {:error, String.t(), keyword()}
  def validate_request_meta(meta) when is_map(meta) do
    with :ok <- validate_protocol_version(meta),
         :ok <- validate_client_capabilities(meta),
         :ok <- validate_client_info(meta) do
      validate_log_level(meta)
    end
  end

  def validate_request_meta(other) do
    {:error, "_meta must be a map, got %{actual}", actual: inspect(other)}
  end

  defp validate_protocol_version(meta) do
    case Map.get(meta, "io.modelcontextprotocol/protocolVersion") do
      version when is_binary(version) -> :ok
      _ -> {:error, "_meta is missing required key %{key}", key: "io.modelcontextprotocol/protocolVersion"}
    end
  end

  defp validate_client_capabilities(meta) do
    case Map.get(meta, "io.modelcontextprotocol/clientCapabilities") do
      capabilities when is_map(capabilities) -> :ok
      _ -> {:error, "_meta is missing required key %{key}", key: "io.modelcontextprotocol/clientCapabilities"}
    end
  end

  defp validate_client_info(meta) do
    case Map.get(meta, "io.modelcontextprotocol/clientInfo") do
      nil -> :ok
      %{"name" => name, "version" => version} when is_binary(name) and is_binary(version) -> :ok
      other -> {:error, "clientInfo must declare a name and version, got %{actual}", actual: inspect(other)}
    end
  end

  defp validate_log_level(meta) do
    case Map.get(meta, "io.modelcontextprotocol/logLevel") do
      nil ->
        :ok

      level when level in @log_levels ->
        :ok

      other ->
        {:error, "logLevel must be one of %{expected}, got %{actual}", expected: Enum.join(@log_levels, ", "),
         actual: inspect(other)}
    end
  end

  @doc """
  Builds a JSON-RPC request branch for a `{:multi, :method, branches}` schema.
  """
  @spec request_branch(String.t(), term()) :: map()
  def request_branch(method, params_schema) do
    %{
      "jsonrpc" => {:required, {:string, {:eq, "2.0"}}},
      "method" => {:required, {:literal, method}},
      "params" => params_schema,
      "id" => {:required, {:either, {:string, :integer}}}
    }
  end

  @doc """
  Builds a JSON-RPC request branch for a version in the `:stateless` era.

  Identical to `request_branch/2` except that `params` is required: the
  per-request `_meta` fields are mandatory on every stateless request, and an
  omitted `params` would otherwise skip validating them entirely.
  """
  @spec stateless_request_branch(String.t(), term()) :: map()
  def stateless_request_branch(method, params_schema) do
    method
    |> request_branch(with_request_meta(params_schema))
    |> Map.update!("params", &{:required, &1})
  end

  @doc """
  Builds a JSON-RPC notification branch for a `{:multi, :method, branches}` schema.
  """
  @spec notification_branch(String.t(), term()) :: map()
  def notification_branch(method, params_schema) do
    %{
      "jsonrpc" => {:required, {:string, {:eq, "2.0"}}},
      "method" => {:required, {:literal, method}},
      "params" => params_schema
    }
  end
end
