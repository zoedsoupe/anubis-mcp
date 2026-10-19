defmodule Anubis.Client.Stateless do
  @moduledoc """
  Stateless-era client logic, as pure functions.

  The client probes `server/discover` before any `initialize`; a server that
  answers in the stateless era is used statelessly from then on, and every
  other probe outcome falls back to the legacy handshake. This module holds
  the decisions that flow needs: `_meta` construction, probe classification,
  version negotiation and the removed-method guard. Data in, decisions out;
  no processes, no IO.

  The era and the negotiated version live in the client GenServer's state
  (`Anubis.Client.State`), which is the whole era cache: one `Anubis.Client`
  process is one connection to one server.
  """

  alias Anubis.MCP.Error
  alias Anubis.Protocol
  alias Anubis.Protocol.Registry
  alias Anubis.Protocol.Schema

  @type era :: :detecting | :connecting | :legacy | :stateless

  # Mirrors Anubis.Protocol.V2026_07_28.request_methods/0 minus what the
  # stateless dialect removed: ping, logging/setLevel, resources/subscribe and
  # resources/unsubscribe (replaced by subscriptions/listen, which the client
  # does not consume yet). Keep both lists in sync when a version removes more.
  @removed_methods ~w(ping logging/setLevel resources/subscribe resources/unsubscribe)

  @doc """
  Returns the version the `server/discover` probe declares.

  The configured version is used when it is itself a stateless version (the
  user pinned the era); otherwise the newest registered stateless version,
  or `nil` when the build registers none.

  ## Examples

      iex> Anubis.Client.Stateless.probe_version("2026-07-28")
      "2026-07-28"

      iex> Anubis.Client.Stateless.probe_version("2025-11-25")
      "2026-07-28"
  """
  @spec probe_version(String.t()) :: String.t() | nil
  def probe_version(configured) do
    if Protocol.era(configured) == {:ok, :stateless} do
      configured
    else
      Registry.latest_version(:stateless)
    end
  end

  @doc """
  Returns the version the legacy `initialize` fallback proposes.

  The configured version when it is legacy; otherwise the newest legacy
  version, since a stateless version is not a legal initialize proposal.

  ## Examples

      iex> Anubis.Client.Stateless.legacy_proposal("2025-06-18")
      "2025-06-18"

      iex> Anubis.Client.Stateless.legacy_proposal("2026-07-28")
      "2025-11-25"
  """
  @spec legacy_proposal(String.t()) :: String.t()
  def legacy_proposal(configured) do
    if Protocol.era(configured) == {:ok, :legacy} do
      configured
    else
      Protocol.latest_version()
    end
  end

  @doc """
  Builds the `_meta` map every stateless-era request carries.

  Capabilities are advertised verbatim: the stateless server gates multi
  round-trip input requests on them, so nothing is stripped.
  `clientInfo` is included only when complete, because the schema requires
  both `name` and `version` when the key is present.

  ## Examples

      iex> meta = Anubis.Client.Stateless.request_meta("2026-07-28", %{"roots" => %{}}, %{"name" => "c", "version" => "1"})
      iex> {meta["io.modelcontextprotocol/protocolVersion"], meta["io.modelcontextprotocol/clientCapabilities"]}
      {"2026-07-28", %{"roots" => %{}}}
      iex> meta["io.modelcontextprotocol/clientInfo"]
      %{"name" => "c", "version" => "1"}

      iex> meta = Anubis.Client.Stateless.request_meta("2026-07-28", %{}, %{"name" => "c"})
      iex> Map.has_key?(meta, "io.modelcontextprotocol/clientInfo")
      false
  """
  @spec request_meta(String.t(), map(), map()) :: map()
  def request_meta(version, capabilities, client_info) when is_binary(version) and is_map(capabilities) do
    meta = %{
      Schema.protocol_version_key() => version,
      Schema.client_capabilities_key() => capabilities
    }

    maybe_put_client_info(meta, client_info)
  end

  defp maybe_put_client_info(meta, %{"name" => name, "version" => version}) when is_binary(name) and is_binary(version) do
    Map.put(meta, Schema.client_info_key(), %{"name" => name, "version" => version})
  end

  defp maybe_put_client_info(meta, _client_info), do: meta

  @doc """
  Puts the request `_meta` into the params, merging a progress token when the
  opts carry one.

  Any user-provided `"_meta"` key is overwritten, matching the legacy
  `add_progress_token_to_params/2` behavior this replaces in the stateless
  era. The `progressToken` shares the `_meta` object with the era keys.

  ## Examples

      iex> meta = %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
      iex> Anubis.Client.Stateless.build_params(meta, %{"cursor" => "a"}, nil)
      %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}, "cursor" => "a"}

      iex> meta = %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
      iex> Anubis.Client.Stateless.build_params(meta, %{}, token: "t1")
      %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28", "progressToken" => "t1"}}
  """
  @spec build_params(map(), map(), keyword() | nil) :: map()
  def build_params(meta, params, progress_opts) when is_map(meta) and is_map(params) do
    Map.put(params, "_meta", put_progress_token(meta, progress_opts))
  end

  defp put_progress_token(meta, progress_opts) when is_list(progress_opts) do
    token = Keyword.get(progress_opts, :token)

    if is_binary(token) or is_integer(token) do
      Map.put(meta, "progressToken", token)
    else
      meta
    end
  end

  defp put_progress_token(meta, _progress_opts), do: meta

  @doc """
  Classifies a `server/discover` result.

  Returns `{:stateless, supported_versions, capabilities, server_info}` for a
  result declaring a binary `supportedVersions` list and a `capabilities` map;
  the server identity is read from the result's `_meta`
  `io.modelcontextprotocol/serverInfo` key when present. Any other shape is
  `:fallback`: the initialize fallback then surfaces whatever is really wrong.

  ## Examples

      iex> result = %{"supportedVersions" => ["2026-07-28"], "capabilities" => %{"tools" => %{}}}
      iex> {:stateless, supported, caps, info} = Anubis.Client.Stateless.classify_probe_result(result)
      iex> {supported, caps, info}
      {["2026-07-28"], %{"tools" => %{}}, nil}

      iex> Anubis.Client.Stateless.classify_probe_result(%{})
      :fallback
  """
  @spec classify_probe_result(term()) :: {:stateless, [String.t()], map(), map() | nil} | :fallback
  def classify_probe_result(result) when is_map(result) do
    supported = Map.get(result, "supportedVersions")
    capabilities = Map.get(result, "capabilities")

    if version_list?(supported) and is_map(capabilities) do
      {:stateless, supported, capabilities, server_info(result["_meta"])}
    else
      :fallback
    end
  end

  def classify_probe_result(_result), do: :fallback

  defp version_list?(versions), do: is_list(versions) and Enum.all?(versions, &is_binary/1)

  defp server_info(%{} = meta), do: server_info_from(meta)
  defp server_info(_meta), do: nil

  defp server_info_from(meta) do
    case Map.get(meta, "io.modelcontextprotocol/serverInfo") do
      info when is_map(info) -> info
      _other -> nil
    end
  end

  @doc """
  Classifies a `server/discover` error.

  An `UnsupportedProtocolVersion` (`-32022`) carrying the versions the server
  serves statelessly is a retry; everything else (including `-32601` on a
  legacy-only server) is `:fallback`.

  ## Examples

      iex> error = %{"code" => -32022, "data" => %{"supported" => ["2026-07-28"]}}
      iex> Anubis.Client.Stateless.classify_probe_error(error)
      {:retry, ["2026-07-28"]}

      iex> Anubis.Client.Stateless.classify_probe_error(%{"code" => -32601, "message" => "Method not found"})
      :fallback
  """
  @spec classify_probe_error(term()) :: {:retry, [String.t()]} | :fallback
  def classify_probe_error(%{"code" => -32_022, "data" => %{"supported" => supported}} = _error)
      when is_list(supported) do
    if Enum.all?(supported, &is_binary/1), do: {:retry, supported}, else: :fallback
  end

  def classify_probe_error(_error), do: :fallback

  @doc """
  Picks the stateless version to speak from the versions the server serves.

  The probe version wins when the server serves it; otherwise the newest
  version of the intersection between the registry and the server's list.
  `:error` means an empty intersection: no stateless conversation is possible.

  ## Examples

      iex> Anubis.Client.Stateless.negotiate("2026-07-28", ["2026-07-28"])
      {:ok, "2026-07-28"}

      iex> Anubis.Client.Stateless.negotiate(nil, ["2026-07-28"])
      {:ok, "2026-07-28"}

      iex> Anubis.Client.Stateless.negotiate("2026-07-28", [])
      :error
  """
  @spec negotiate(String.t() | nil, [String.t()]) :: {:ok, String.t()} | :error
  def negotiate(preferred, supported) when is_list(supported) do
    stateless = Registry.stateless_versions()
    candidates = Enum.filter(supported, &(&1 in stateless))

    cond do
      is_binary(preferred) and preferred in candidates ->
        {:ok, preferred}

      candidates != [] ->
        {:ok, Enum.max(candidates)}

      true ->
        :error
    end
  end

  def negotiate(_preferred, _supported), do: :error

  @doc """
  Refuses the request methods the stateless dialect removed.

  Only a client detected as `:stateless` gets the error: a legacy client may
  still call all four, and any other method passes in every era. The server
  never executed a request it refused at admission, so this guard only
  prevents a doomed encode from leaving the client.

  ## Examples

      iex> {:error, error} = Anubis.Client.Stateless.validate_method(:stateless, "ping")
      iex> {error.reason, error.data.method, error.data.era}
      {:method_not_found, "ping", :stateless}

      iex> Anubis.Client.Stateless.validate_method(:stateless, "tools/list")
      :ok

      iex> Anubis.Client.Stateless.validate_method(:legacy, "ping")
      :ok
  """
  @spec validate_method(era(), String.t()) :: :ok | {:error, Error.t()}
  def validate_method(:stateless, method) when method in @removed_methods do
    {:error,
     Error.protocol(:method_not_found, %{
       method: method,
       era: :stateless,
       message: "removed in the stateless era"
     })}
  end

  def validate_method(_era, _method), do: :ok
end
