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

  ## Examples

  A stateless version builds each request branch from its params schema, and the
  helper adds the mandatory `_meta` slot and requires `params`:

      iex> branch = Anubis.Protocol.Schema.stateless_request_branch("tools/list", %{"cursor" => :string})
      iex> {:required, params} = branch["params"]
      iex> Map.keys(params)
      ["_meta", "cursor"]
  """

  @progress_meta %{"_meta" => %{"progressToken" => {:either, {:string, :integer}}}}

  @log_levels ~w(debug info notice warning error critical alert emergency)

  @request_meta %{"_meta" => {:required, {:custom, &__MODULE__.validate_request_meta/1}}}

  @subscription_meta %{"_meta" => {:required, {:custom, &__MODULE__.validate_subscription_meta/1}}}

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

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

  ## Examples

      iex> Anubis.Protocol.Schema.log_levels()
      ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]
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

  ## Examples

      iex> Anubis.Protocol.Schema.with_request_meta(%{"cursor" => :string}) |> Map.keys()
      ["_meta", "cursor"]

      iex> Anubis.Protocol.Schema.with_request_meta(:map)
      :map
  """
  @spec with_request_meta(term()) :: term()
  def with_request_meta(schema) when is_map(schema), do: Map.merge(schema, @request_meta)
  def with_request_meta(schema), do: schema

  @doc """
  Validates the reserved `io.modelcontextprotocol/*` keys of a stateless-era
  request's `_meta`, returning the map unchanged so unmodeled keys survive.

  `protocolVersion` and `clientCapabilities` are required on every request;
  `clientInfo` and `logLevel` are optional but validated when present.

  ## Examples

      iex> Anubis.Protocol.Schema.validate_request_meta(%{
      ...>   "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      ...>   "io.modelcontextprotocol/clientCapabilities" => %{}
      ...> })
      :ok

      iex> {:error, message, _binding} = Anubis.Protocol.Schema.validate_request_meta(%{})
      iex> message
      "_meta is missing required key %{key}"
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

  @doc """
  Returns the `_meta` slot required on notifications delivered over a
  `subscriptions/listen` stream.

  Every message on the stream must be tagged with the subscription it belongs
  to, so clients can demultiplex them on transports that share one channel.

  ## Examples

      iex> Anubis.Protocol.Schema.subscription_meta() |> Map.keys()
      ["_meta"]
  """
  @spec subscription_meta() :: map()
  def subscription_meta, do: @subscription_meta

  @doc """
  Validates that a subscription notification's `_meta` carries
  `io.modelcontextprotocol/subscriptionId`, returning the map unchanged so
  unmodeled keys survive.

  The value is the JSON-RPC id of the originating `subscriptions/listen`
  request, so it is a string or an integer.

  ## Examples

      iex> Anubis.Protocol.Schema.validate_subscription_meta(%{"io.modelcontextprotocol/subscriptionId" => 4})
      :ok

      iex> {:error, message, _binding} = Anubis.Protocol.Schema.validate_subscription_meta(%{})
      iex> message
      "_meta is missing required key %{key}"
  """
  @spec validate_subscription_meta(term()) :: :ok | {:error, String.t(), keyword()}
  def validate_subscription_meta(meta) when is_map(meta) do
    case Map.get(meta, @subscription_id_key) do
      id when is_binary(id) or is_integer(id) ->
        :ok

      nil ->
        {:error, "_meta is missing required key %{key}", key: @subscription_id_key}

      other ->
        {:error, "%{key} must be a string or an integer, got %{actual}", key: @subscription_id_key,
         actual: inspect(other)}
    end
  end

  def validate_subscription_meta(other) do
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

  Raises when `params_schema` is not a map. `with_request_meta/1` passes
  non-map schemas through untouched, so an open schema such as `:map` would
  silently drop the mandatory `_meta` slot; failing here surfaces a request
  method that has no params schema instead of accepting it unvalidated.

  ## Examples

      iex> branch = Anubis.Protocol.Schema.stateless_request_branch("server/discover", %{})
      iex> branch["method"]
      {:required, {:literal, "server/discover"}}
  """
  @spec stateless_request_branch(String.t(), term()) :: map()
  def stateless_request_branch(method, params_schema) when is_map(params_schema) do
    method
    |> request_branch(with_request_meta(params_schema))
    |> Map.update!("params", &{:required, &1})
  end

  def stateless_request_branch(method, params_schema) do
    raise ArgumentError,
          "#{method}: a stateless request params schema must be a map to carry the " <>
            "required _meta slot, got #{inspect(params_schema)}"
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
