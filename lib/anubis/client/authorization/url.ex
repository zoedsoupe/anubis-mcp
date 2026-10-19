defmodule Anubis.Client.Authorization.URL do
  @moduledoc false

  @doc "Validates an absolute HTTPS URL, allowing loopback HTTP only with explicit opt-in."
  @spec validate(String.t(), keyword()) :: :ok | {:error, :invalid_discovery_url}
  def validate(url, opts) when is_binary(url) do
    with {:ok, uri} <- URI.new(url),
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment),
         true <- is_integer(uri.port) and uri.port in 1..65_535,
         true <- secure?(uri, opts) do
      :ok
    else
      _ -> {:error, :invalid_discovery_url}
    end
  end

  def validate(_, _), do: {:error, :invalid_discovery_url}

  @doc "Returns the origin of a validated URL, without its path, query or fragment."
  @spec origin(String.t()) :: String.t()
  def origin(url) do
    uri = URI.new!(url)
    URI.to_string(%{uri | path: nil, query: nil, fragment: nil})
  end

  @doc "Inserts a well-known metadata suffix before a validated URL's path, preserving its query."
  @spec well_known(String.t(), String.t()) :: String.t()
  def well_known(url, suffix) do
    uri = URI.new!(url)
    path = String.trim_trailing(uri.path || "", "/")
    URI.to_string(%{uri | path: "/.well-known/" <> suffix <> path})
  end

  defp secure?(%URI{scheme: "https"}, _opts), do: true

  defp secure?(%URI{scheme: "http", host: host}, opts) do
    Keyword.get(opts, :allow_insecure_localhost, false) and host in ["localhost", "127.0.0.1", "::1"]
  end

  defp secure?(_, _), do: false
end
