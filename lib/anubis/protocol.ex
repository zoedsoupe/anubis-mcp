defmodule Anubis.Protocol do
  @moduledoc """
  MCP protocol version management.

  Provides version validation, negotiation, feature detection, and transport
  compatibility checking. Delegates version-specific logic to modules under
  `Anubis.Protocol.*` via `Anubis.Protocol.Registry`.

  ## Adding a new protocol version

  1. Create a new module under `lib/anubis/protocol/` implementing `Anubis.Protocol.Behaviour`
  2. Register it in `Anubis.Protocol.Registry`
  """

  alias Anubis.MCP.Error
  alias Anubis.Protocol.Registry

  @type version :: String.t()
  @type feature :: atom()

  @doc """
  Returns all supported protocol versions.
  """
  @spec supported_versions() :: [version()]
  defdelegate supported_versions(), to: Registry

  @doc """
  Returns the latest supported protocol version.
  """
  @spec latest_version() :: version()
  defdelegate latest_version(), to: Registry

  @doc """
  Returns the fallback protocol version for compatibility.
  """
  @spec fallback_version() :: version()
  defdelegate fallback_version(), to: Registry

  @doc """
  Validates if a protocol version is supported.
  """
  @spec validate_version(version()) :: :ok | {:error, Error.t()}
  def validate_version(version) do
    if Registry.supported?(version) do
      :ok
    else
      {:error,
       Error.protocol(:invalid_params, %{
         version: version,
         supported: supported_versions()
       })}
    end
  end

  @doc """
  Validates if a transport is compatible with a protocol version.
  """
  @spec validate_transport(version(), module()) :: :ok | {:error, Error.t()}
  def validate_transport(version, transport) do
    supported_versions = supported_transport_versions(transport)

    if version in supported_versions do
      :ok
    else
      {:error,
       Error.transport(:incompatible_transport, %{
         version: version,
         transport: transport,
         supported_versions: supported_versions
       })}
    end
  end

  defp supported_transport_versions(transport) do
    case transport.supported_protocol_versions() do
      :all -> supported_versions()
      [_ | _] = versions -> versions
    end
  end

  @doc """
  Returns the set of features supported by a protocol version.

  Delegates to the version module's `supported_features/0` callback.
  """
  @spec get_features(version()) :: list(feature())
  def get_features(version) do
    case Registry.get_features(version) do
      {:ok, features} -> features
      :error -> []
    end
  end

  @doc """
  Checks if a feature is supported by a protocol version.
  """
  @spec supports_feature?(version(), feature()) :: boolean()
  defdelegate supports_feature?(version, feature), to: Registry

  @doc """
  Negotiates protocol version between client and server versions.

  Returns the best compatible version or an error if incompatible.
  """
  @spec negotiate_version(version(), version()) ::
          {:ok, version()} | {:error, Error.t()}
  def negotiate_version(client_version, server_version) do
    cond do
      client_version == server_version and Registry.supported?(client_version) ->
        {:ok, client_version}

      Registry.supported?(server_version) ->
        {:ok, server_version}

      Registry.supported?(client_version) ->
        {:ok, client_version}

      true ->
        {:error,
         Error.protocol(:invalid_params, %{
           client_version: client_version,
           server_version: server_version,
           supported: supported_versions()
         })}
    end
  end

  @doc """
  Returns the protocol module for a given version string.

  ## Examples

      iex> Anubis.Protocol.get_module("2025-06-18")
      {:ok, Anubis.Protocol.V2025_06_18}
  """
  @spec get_module(version()) :: {:ok, module()} | :error
  defdelegate get_module(version), to: Registry, as: :get

  @doc """
  Returns transport modules that support a protocol version.
  """
  @spec compatible_transports(version(), [module()]) :: [module()]
  def compatible_transports(version, transport_modules) do
    Enum.filter(transport_modules, fn transport_module ->
      case validate_transport(version, transport_module) do
        :ok -> true
        {:error, _} -> false
      end
    end)
  end

  @doc """
  Validates client configuration for protocol compatibility.

  This function checks if the client configuration is compatible with
  the specified protocol version, including transport and capabilities.
  """
  @spec validate_client_config(version(), module(), map()) ::
          :ok | {:error, Error.t()}
  def validate_client_config(version, transport_module, _capabilities) do
    with :ok <- validate_version(version) do
      validate_transport(version, transport_module)
    end
  end
end
