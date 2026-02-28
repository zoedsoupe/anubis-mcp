defmodule Anubis.Protocol.Registry do
  @moduledoc """
  Registry for MCP protocol version modules.

  Maps version strings to their implementing modules, supports version negotiation,
  and provides the central dispatch point for version-specific protocol logic.

  ## Usage

      iex> Anubis.Protocol.Registry.get("2025-06-18")
      {:ok, Anubis.Protocol.V2025_06_18}

      iex> Anubis.Protocol.Registry.supported_versions()
      ["2025-06-18", "2025-03-26", "2024-11-05"]

      iex> Anubis.Protocol.Registry.negotiate("2025-03-26")
      {:ok, "2025-03-26", Anubis.Protocol.V2025_03_26}
  """

  @versions %{
    "2024-11-05" => Anubis.Protocol.V2024_11_05,
    "2025-03-26" => Anubis.Protocol.V2025_03_26,
    "2025-06-18" => Anubis.Protocol.V2025_06_18
  }

  @latest_version "2025-06-18"
  @fallback_version "2025-03-26"

  @type version :: String.t()

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
  Returns the latest supported protocol version string.
  """
  @spec latest_version() :: version()
  def latest_version, do: @latest_version

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

  ## Examples

      iex> Anubis.Protocol.Registry.negotiate("2025-06-18")
      {:ok, "2025-06-18", Anubis.Protocol.V2025_06_18}

      iex> Anubis.Protocol.Registry.negotiate("9999-01-01")
      {:error, :unsupported_version, ["2025-06-18", "2025-03-26", "2024-11-05"]}
  """
  @spec negotiate(version()) :: {:ok, version(), module()} | {:error, :unsupported_version, [version()]}
  def negotiate(client_version) do
    case get(client_version) do
      {:ok, mod} -> {:ok, client_version, mod}
      :error -> {:error, :unsupported_version, supported_versions()}
    end
  end

  @doc """
  Negotiate version between client and server supported version lists.

  Used when the server has a restricted set of supported versions.
  Returns the best matching version (client's preference if in server list,
  otherwise server's latest).

  ## Examples

      iex> Anubis.Protocol.Registry.negotiate("2025-03-26", ["2025-06-18", "2025-03-26"])
      {:ok, "2025-03-26", Anubis.Protocol.V2025_03_26}

      iex> Anubis.Protocol.Registry.negotiate("2024-11-05", ["2025-06-18", "2025-03-26"])
      {:ok, "2025-06-18", Anubis.Protocol.V2025_06_18}
  """
  @spec negotiate(version(), [version()]) :: {:ok, version(), module()} | :error
  def negotiate(client_version, [latest | _] = server_versions) do
    version =
      if client_version in server_versions do
        client_version
      else
        latest
      end

    case get(version) do
      {:ok, mod} -> {:ok, version, mod}
      :error -> :error
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
end
