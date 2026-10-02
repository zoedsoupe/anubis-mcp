defmodule Anubis.Server.Stateless do
  @moduledoc """
  Serving requests of the `:stateless` protocol era.

  Versions in this era (MCP 2026-07-28 onward) have no `initialize` handshake:
  every request carries its own protocol version, client capabilities and
  client identity under the reserved `io.modelcontextprotocol/*` keys of
  `params._meta`. A request bearing that metadata is what tells a dual-era
  server to serve it statelessly.

  Because the specification forbids inferring capabilities from earlier
  requests, `admit/2` returns a context that lives only for the request that
  produced it. Nothing here writes to session state.
  """

  alias Anubis.MCP.Error
  alias Anubis.Protocol.Registry
  alias Anubis.Protocol.Schema

  @protocol_version_key Schema.protocol_version_key()
  @client_capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @client_info_key "io.modelcontextprotocol/clientInfo"
  @log_level_key "io.modelcontextprotocol/logLevel"
  @server_info_key "io.modelcontextprotocol/serverInfo"

  @cacheable_methods ~w(server/discover tools/list prompts/list resources/list resources/templates/list resources/read)
  @default_cache_hints %{ttl_ms: 0, scope: :private}

  @type t :: %{
          protocol_version: String.t(),
          protocol_module: module(),
          client_capabilities: map(),
          client_info: map() | nil,
          log_level: String.t() | nil
        }

  @doc """
  Returns the era a request served by `protocol_module` belongs to.

  `nil` means no version has been settled yet, which happens only before a
  legacy handshake completes.

  ## Examples

      iex> Anubis.Server.Stateless.era(Anubis.Protocol.V2026_07_28)
      :stateless

      iex> Anubis.Server.Stateless.era(nil)
      :legacy
  """
  @spec era(module() | nil) :: Anubis.Protocol.Behaviour.era()
  def era(nil), do: :legacy
  def era(protocol_module), do: protocol_module.era()

  @doc """
  Returns the key a stateless result carries the server identity under.

  ## Examples

      iex> Anubis.Server.Stateless.server_info_key()
      "io.modelcontextprotocol/serverInfo"
  """
  @spec server_info_key() :: String.t()
  def server_info_key, do: @server_info_key

  @doc """
  Whether a decoded message asks to be served under the stateless era.

  True exactly when `params._meta` declares a protocol version, which is the
  discriminator the specification gives a dual-era server.

  ## Examples

      iex> meta = %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
      iex> Anubis.Server.Stateless.request?(%{"params" => %{"_meta" => meta}})
      true

      iex> Anubis.Server.Stateless.request?(%{"method" => "initialize", "params" => %{}})
      false
  """
  @spec request?(term()) :: boolean()
  def request?(%{"params" => %{"_meta" => %{@protocol_version_key => version}}}), do: is_binary(version)
  def request?(_message), do: false

  @doc """
  Narrows the versions a server declares to the ones it can serve statelessly.

  Ordering follows the registry, newest first, so the list never depends on
  how the server happened to declare its versions. This is the list a client
  may pick from, so it feeds both `server/discover` and the
  `UnsupportedProtocolVersion` payload.

  ## Examples

      iex> Anubis.Server.Stateless.supported_versions(["2025-11-25", "2026-07-28"])
      ["2026-07-28"]

      iex> Anubis.Server.Stateless.supported_versions(["2025-11-25"])
      []
  """
  @spec supported_versions([String.t()]) :: [String.t()]
  def supported_versions(declared_versions) when is_list(declared_versions) do
    Enum.filter(Registry.stateless_versions(), &(&1 in declared_versions))
  end

  @doc """
  Resolves the per-request context of a stateless request.

  Returns an `UnsupportedProtocolVersion` error (`-32022`) when the server does
  not serve the requested version, carrying the versions the client may retry
  with.

  Only defined for a message `request?/1` accepts; any other shape is a caller
  error and raises.

  ## Examples

      iex> meta = %{
      ...>   "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      ...>   "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
      ...> }
      iex> {:ok, context} = Anubis.Server.Stateless.admit(%{"params" => %{"_meta" => meta}}, ["2026-07-28"])
      iex> {context.protocol_version, context.client_capabilities}
      {"2026-07-28", %{"elicitation" => %{}}}

      iex> meta = %{"io.modelcontextprotocol/protocolVersion" => "1900-01-01"}
      iex> {:error, error} = Anubis.Server.Stateless.admit(%{"params" => %{"_meta" => meta}}, ["2026-07-28"])
      iex> {error.code, error.data}
      {-32022, %{supported: ["2026-07-28"], requested: "1900-01-01"}}
  """
  @spec admit(map(), [String.t()]) :: {:ok, t()} | {:error, Error.t()}
  def admit(%{"params" => %{"_meta" => %{@protocol_version_key => version} = meta}}, declared_versions)
      when is_binary(version) and is_list(declared_versions) do
    supported = supported_versions(declared_versions)

    with true <- version in supported,
         {:ok, protocol_module} <- Registry.get(version) do
      {:ok,
       %{
         protocol_version: version,
         protocol_module: protocol_module,
         client_capabilities: Map.get(meta, @client_capabilities_key, %{}),
         client_info: Map.get(meta, @client_info_key),
         log_level: Map.get(meta, @log_level_key)
       }}
    else
      _unsupported -> {:error, Error.unsupported_protocol_version(version, supported)}
    end
  end

  @doc """
  Stores a request context on the transport context that travels with a
  request.

  Request scoping is what the transport context already gives us: the session
  hands it to the scheduler, which carries it through the request queue and
  into the frame. Nothing about the client is written to session state, so
  nothing can leak into the next request.

  ## Examples

      iex> Anubis.Server.Stateless.put_context(%{assigns: %{}}, %{protocol_version: "2026-07-28"})
      %{assigns: %{}, stateless: %{protocol_version: "2026-07-28"}}
  """
  @spec put_context(map() | nil, t()) :: map()
  def put_context(transport_context, context) when is_map(transport_context) do
    Map.put(transport_context, :stateless, context)
  end

  def put_context(_transport_context, context), do: %{stateless: context}

  @doc """
  Reads the request context back off a transport context.

  Returns `nil` for a request served under the legacy era.

  ## Examples

      iex> Anubis.Server.Stateless.context(%{stateless: %{protocol_version: "2026-07-28"}})
      %{protocol_version: "2026-07-28"}

      iex> Anubis.Server.Stateless.context(%{assigns: %{}})
      nil
  """
  @spec context(map() | nil) :: t() | nil
  def context(%{stateless: context}) when is_map(context), do: context
  def context(_transport_context), do: nil

  @doc """
  Builds the `server/discover` result for a server module.

  `supportedVersions` narrows the server's declared versions to the stateless
  era: a legacy version cannot be selected per request, so advertising one
  would name a version the client could not retry with. Capabilities are
  filtered through the dialect, exactly as the `initialize` handshake filters
  them for legacy clients.

  Cache hints are conservative — components may be registered at runtime
  through the frame, so a result cached for longer than the current request
  could be wrong.
  """
  @spec discover_result(module(), module()) :: map()
  def discover_result(server, protocol_module) when is_atom(protocol_module) do
    result =
      Map.merge(
        %{
          "supportedVersions" => supported_versions(server.supported_protocol_versions()),
          "capabilities" => protocol_module.server_capabilities(server.server_capabilities())
        },
        cache_hints(server, "server/discover", false)
      )

    maybe_put_instructions(result, server)
  end

  @doc """
  Completes a handler result with the fields every stateless result carries.

  `resultType` is mandatory in this era; `input_required` results arrive with
  the multi round-trip requests pattern, so a completed handler result is
  always `"complete"`. The server identity is advertised under the result
  `_meta`, which a handler may already have populated.

  A complete result gets `cache_hints` under any it set itself, except that a
  multi round-trip retry (`retry?`) always says `"ttlMs" => 0`.

  ## Examples

      iex> info = %{"name" => "demo", "version" => "1.0.0"}
      iex> Anubis.Server.Stateless.shape_result(%{"tools" => []}, info)
      %{
        "tools" => [],
        "resultType" => "complete",
        "_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => "demo", "version" => "1.0.0"}}
      }
  """
  @spec shape_result(map(), map() | nil, map() | nil, boolean()) :: map()
  def shape_result(result, server_info, cache_hints \\ nil, retry? \\ false)
      when is_map(result) and not is_struct(result) do
    result
    |> Map.put_new("resultType", "complete")
    |> put_cache_hints(cache_hints, retry?)
    |> put_server_info(server_info)
  end

  @doc """
  Returns the `ttlMs` and `cacheScope` a complete stateless result of `method`
  carries, or `nil` for a method whose results are not cacheable.

  They come from the server's `c:Anubis.Server.cache_hints/1` when it defines
  one, and are `0` and `"private"` otherwise. A multi round-trip retry
  (`retry?`) depends on client input the cache key does not hold, so its result
  is always stale at once.

  ## Examples

      iex> Anubis.Server.Stateless.cache_hints(StubServer, "tools/list", false)
      %{"ttlMs" => 0, "cacheScope" => "private"}

      iex> Anubis.Server.Stateless.cache_hints(StubServer, "tools/call", false)
      nil
  """
  @spec cache_hints(module(), String.t(), boolean()) :: %{String.t() => term()} | nil
  def cache_hints(server, method, retry?) when method in @cacheable_methods do
    hints =
      if Anubis.exported?(server, :cache_hints, 1),
        do: server.cache_hints(method),
        else: @default_cache_hints

    hints
    |> then(&if(retry?, do: %{&1 | ttl_ms: 0}, else: &1))
    |> wire_hints(server, method)
  end

  def cache_hints(_server, _method, _retry?), do: nil

  defp wire_hints(%{ttl_ms: ttl, scope: scope}, _server, _method)
       when is_integer(ttl) and ttl >= 0 and scope in [:public, :private] do
    %{"ttlMs" => ttl, "cacheScope" => Atom.to_string(scope)}
  end

  defp wire_hints(hints, server, method) do
    raise ArgumentError,
          "#{inspect(server)}.cache_hints(#{inspect(method)}) must return %{ttl_ms: non_neg_integer, " <>
            "scope: :public | :private}, got: #{inspect(hints)}"
  end

  # Only a complete result is cacheable; a handler's own hints are kept, except
  # a retry's TTL, since the cache key does not hold the client input it used.
  defp put_cache_hints(%{"resultType" => "complete"} = result, %{} = hints, retry?) do
    merged = Map.merge(hints, result)
    if retry?, do: Map.put(merged, "ttlMs", 0), else: merged
  end

  defp put_cache_hints(result, _hints, _retry?), do: result

  defp maybe_put_instructions(result, server) do
    if Anubis.exported?(server, :server_instructions, 0) do
      put_instructions(result, server.server_instructions())
    else
      result
    end
  end

  defp put_instructions(result, nil), do: result
  defp put_instructions(result, instructions), do: Map.put(result, "instructions", instructions)

  defp put_server_info(result, nil), do: result

  defp put_server_info(result, server_info) do
    meta =
      result
      |> Map.get("_meta", %{})
      |> Map.put_new(@server_info_key, server_info)

    Map.put(result, "_meta", meta)
  end
end
