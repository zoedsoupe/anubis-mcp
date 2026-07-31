defmodule Anubis.Protocol.Registry do
  @moduledoc """
  Registry for MCP protocol version modules.

  Maps version strings to their implementing modules, supports version negotiation,
  and provides the central dispatch point for version-specific protocol logic.

  ## Eras

  Registered versions group into the eras defined by
  `Anubis.Protocol.Behaviour` — `:legacy` versions negotiate a session with
  the `initialize` handshake, `:stateless` versions carry their metadata on
  every request. The grouping is derived from each module's `c:Anubis.Protocol.Behaviour.era/0`
  callback, so registering a version is still a single entry in `@versions`.

  Because the two eras open a connection in structurally different ways, they
  negotiate separately: `negotiate/1` and `negotiate/2` serve the `initialize`
  handshake and therefore only ever resolve to a `:legacy` version.

  ## Usage

      iex> Anubis.Protocol.Registry.get("2025-11-25")
      {:ok, Anubis.Protocol.V2025_11_25}

      iex> Anubis.Protocol.Registry.supported_versions()
      ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

      iex> Anubis.Protocol.Registry.versions_for_era(:stateless)
      ["2026-07-28"]

      iex> Anubis.Protocol.Registry.negotiate("2025-03-26")
      {:ok, "2025-03-26", Anubis.Protocol.V2025_03_26}
  """

  @versions %{
    "2024-11-05" => Anubis.Protocol.V2024_11_05,
    "2025-03-26" => Anubis.Protocol.V2025_03_26,
    "2025-06-18" => Anubis.Protocol.V2025_06_18,
    "2025-11-25" => Anubis.Protocol.V2025_11_25,
    "2026-07-28" => Anubis.Protocol.V2026_07_28
  }

  @versions_by_era @versions
                   |> Enum.group_by(fn {_version, mod} -> mod.era() end, fn {version, _mod} -> version end)
                   |> Map.new(fn {era, versions} -> {era, Enum.sort(versions, :desc)} end)

  @latest_version hd(@versions_by_era[:legacy])
  @fallback_version "2025-03-26"

  @type version :: String.t()
  @type era :: Anubis.Protocol.Behaviour.era()

  @doc """
  Get the protocol module for a given version string.

  ## Examples

      iex> Anubis.Protocol.Registry.get("2025-06-18")
      {:ok, Anubis.Protocol.V2025_06_18}

      iex> Anubis.Protocol.Registry.get("unknown")
      :error
  """
  @spec get(version()) :: {:ok, module()} | :error
  def get(version), do: Map.fetch(@versions, version)

  @doc """
  List all supported versions in preference order (newest first).
  """
  @spec supported_versions() :: [version()]
  def supported_versions do
    @versions |> Map.keys() |> Enum.sort(:desc)
  end

  @doc """
  List the versions belonging to an era, in preference order (newest first).

  ## Examples

      iex> Anubis.Protocol.Registry.versions_for_era(:stateless)
      ["2026-07-28"]
  """
  @spec versions_for_era(era()) :: [version()]
  def versions_for_era(era) when era in [:legacy, :stateless] do
    Map.get(@versions_by_era, era, [])
  end

  @doc """
  List the versions that negotiate a session with the `initialize` handshake.
  """
  @spec legacy_versions() :: [version()]
  def legacy_versions, do: versions_for_era(:legacy)

  @doc """
  List the versions that carry their metadata on every request.
  """
  @spec stateless_versions() :: [version()]
  def stateless_versions, do: versions_for_era(:stateless)

  @doc """
  Returns the era a version belongs to.

  ## Examples

      iex> Anubis.Protocol.Registry.era("2026-07-28")
      {:ok, :stateless}

      iex> Anubis.Protocol.Registry.era("unknown")
      :error
  """
  @spec era(version()) :: {:ok, era()} | :error
  def era(version) do
    case get(version) do
      {:ok, mod} -> {:ok, mod.era()}
      :error -> :error
    end
  end

  @doc """
  Returns the latest protocol version reachable through the `initialize`
  handshake.

  Stateless versions are not handshake-negotiable; use `latest_version/1` to
  ask for the newest version of a specific era.
  """
  @spec latest_version() :: version()
  def latest_version, do: @latest_version

  @doc """
  Returns the latest supported version of an era, or `nil` when none is
  registered.

  ## Examples

      iex> Anubis.Protocol.Registry.latest_version(:stateless)
      "2026-07-28"
  """
  @spec latest_version(era()) :: version() | nil
  def latest_version(era) do
    case versions_for_era(era) do
      [latest | _] -> latest
      [] -> nil
    end
  end

  @doc """
  Returns the fallback protocol version for compatibility.
  """
  @spec fallback_version() :: version()
  def fallback_version, do: @fallback_version

  @doc """
  Returns the module for the latest supported protocol version.
  """
  @spec latest_module() :: module()
  def latest_module, do: @versions[@latest_version]

  @doc """
  Check if a version string is supported.
  """
  @spec supported?(version()) :: boolean()
  def supported?(version), do: Map.has_key?(@versions, version)

  @doc """
  Negotiate the best version given a client's requested version.

  MCP spec: the server picks the version, the client proposes one.
  If we support the requested version, use it. Otherwise, return an error
  with the list of supported versions.

  This serves the `initialize` handshake, so it only resolves to `:legacy`
  versions — a stateless version requested here is treated as unsupported.

  ## Examples

      iex> Anubis.Protocol.Registry.negotiate("2025-11-25")
      {:ok, "2025-11-25", Anubis.Protocol.V2025_11_25}

      iex> Anubis.Protocol.Registry.negotiate("9999-01-01")
      {:error, :unsupported_version, ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]}

      iex> Anubis.Protocol.Registry.negotiate("2026-07-28")
      {:error, :unsupported_version, ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]}
  """
  @spec negotiate(version()) :: {:ok, version(), module()} | {:error, :unsupported_version, [version()]}
  def negotiate(client_version) do
    case legacy_module(client_version) do
      {:ok, mod} -> {:ok, client_version, mod}
      :error -> {:error, :unsupported_version, legacy_versions()}
    end
  end

  @doc """
  Negotiate version between client and server supported version lists.

  Used when the server has a restricted set of supported versions.
  Returns the client's preference when the server offers it, otherwise the
  newest legacy version the server offers, regardless of the order they were
  given in.

  Non-legacy and unregistered entries are ignored, and a server list that
  offers no legacy version returns `:error` rather than silently substituting
  another version.

  ## Examples

      iex> Anubis.Protocol.Registry.negotiate("2025-03-26", ["2025-11-25", "2025-03-26"])
      {:ok, "2025-03-26", Anubis.Protocol.V2025_03_26}

      iex> Anubis.Protocol.Registry.negotiate("2024-11-05", ["2025-11-25", "2025-03-26"])
      {:ok, "2025-11-25", Anubis.Protocol.V2025_11_25}

      iex> Anubis.Protocol.Registry.negotiate("2024-11-05", ["2025-03-26", "2025-11-25"])
      {:ok, "2025-11-25", Anubis.Protocol.V2025_11_25}

      iex> Anubis.Protocol.Registry.negotiate("2026-07-28", ["2026-07-28"])
      :error
  """
  @spec negotiate(version(), [version()]) :: {:ok, version(), module()} | :error
  def negotiate(client_version, server_versions) when is_list(server_versions) do
    legacy = legacy_versions()

    case Enum.filter(server_versions, &(&1 in legacy)) do
      [] ->
        :error

      candidates ->
        version = if client_version in candidates, do: client_version, else: Enum.max(candidates)

        with {:ok, mod} <- legacy_module(version), do: {:ok, version, mod}
    end
  end

  @doc """
  Returns the features supported by a given version.

  Delegates to the version module's `supported_features/0` callback.
  """
  @spec get_features(version()) :: {:ok, [atom()]} | :error
  def get_features(version) do
    case get(version) do
      {:ok, mod} -> {:ok, mod.supported_features()}
      :error -> :error
    end
  end

  @doc """
  Checks if a feature is supported by a protocol version.
  """
  @spec supports_feature?(version(), atom()) :: boolean()
  def supports_feature?(version, feature) when is_binary(version) and is_atom(feature) do
    case get_features(version) do
      {:ok, features} -> feature in features
      :error -> false
    end
  end

  @doc """
  Returns the progress notification params schema for a given version.

  Delegates to the version module's `progress_params_schema/0` callback.
  """
  @spec progress_params_schema(version()) :: {:ok, map()} | :error
  def progress_params_schema(version) do
    case get(version) do
      {:ok, mod} -> {:ok, mod.progress_params_schema()}
      :error -> :error
    end
  end

  defp legacy_module(version) do
    with {:ok, mod} <- get(version),
         :legacy <- mod.era() do
      {:ok, mod}
    else
      _ -> :error
    end
  end
end
