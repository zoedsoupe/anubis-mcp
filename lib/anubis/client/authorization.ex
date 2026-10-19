defmodule Anubis.Client.Authorization do
  @moduledoc """
  Discovers the OAuth configuration of a protected MCP HTTP endpoint.

  Discovery stops at validated metadata: consent, client registration, PKCE,
  token storage and refresh belong to the host application's OAuth client.
  Uses an application-owned Finch pool, just like the HTTP transport.
  """

  import Peri

  alias Anubis.Client.Authorization.Challenge
  alias Anubis.Client.Authorization.Metadata
  alias Anubis.Client.Authorization.URL
  alias Anubis.MCP.Error

  @max_metadata_bytes 1_048_576
  @default_http_options [receive_timeout: 5_000, request_timeout: 10_000]

  defschema(:resource_schema, %{
    "resource" => {:required, :string},
    "authorization_servers" => {:required, {:list, :string}},
    "scopes_supported" => {:list, :string}
  })

  defschema(:server_schema, %{
    "issuer" => {:required, :string},
    "authorization_endpoint" => {:required, :string},
    "token_endpoint" => {:required, :string},
    "registration_endpoint" => :string,
    "scopes_supported" => {:list, :string},
    "grant_types_supported" => {:list, :string},
    "response_types_supported" => {:required, {:list, :string}},
    "code_challenge_methods_supported" => {:list, :string},
    "token_endpoint_auth_methods_supported" => {:list, :string},
    "client_id_metadata_document_supported" => :boolean
  })

  @doc """
  Discovers resource metadata and OAuth/OIDC authorization server metadata.

      {:ok, metadata} = Anubis.Client.Authorization.discover("https://example.com/mcp")

  Options:

    * `:challenge` — a `Challenge` returned by the HTTP transport, for reactive discovery.
    * `:authorization_server` — selects an advertised issuer; required when more than one is advertised.
    * `:finch_name` — an existing Finch pool (default `Anubis.Finch`).
    * `:http_options` — Finch request options (defaults `receive_timeout: 5_000`,
      `request_timeout: 10_000`). HTTP/1 uses an idle receive timeout and a best-effort
      total response timeout. Finch HTTP/2 uses `receive_timeout` as a total response
      timeout and ignores `request_timeout`. Overrides may relax or disable these limits.
    * `:allow_insecure_localhost` — permits HTTP on localhost/loopback for development (default false).
    * `:url_policy` — optional `fn url -> :ok | {:error, reason} end`, called before each metadata fetch.
      Hosts accepting untrusted server URLs must enforce their network access policy here
      and at the network layer, including private-address and DNS-rebinding restrictions.

  Metadata requests carry no credentials, do not follow redirects and accept at most
  1 MiB. Discovery falls back on 404/405; invalid documents fail validation. Missing
  metadata returns an error and does not establish that authorization is unnecessary.

  Errors are `Anubis.MCP.Error` structs. A multiple-issuer error includes
  `data.authorization_servers` so the host can select one and retry.
  """
  @spec discover(String.t(), keyword()) :: {:ok, Metadata.t()} | {:error, Error.t()}
  def discover(mcp_url, opts \\ []) do
    challenge = Keyword.get(opts, :challenge)

    with :ok <- validate_url(mcp_url, opts),
         :ok <- validate_challenge(challenge, mcp_url),
         {:ok, resource, metadata_uri} <- discover_resource(mcp_url, challenge, opts),
         {:ok, issuer} <- select_issuer(resource["authorization_servers"], opts),
         :ok <- validate_issuer(issuer, opts),
         {:ok, server, _uri} <- fetch_first(server_metadata_urls(issuer), opts),
         {:ok, server} <- validate_server(server, issuer, opts) do
      {:ok, build_metadata(mcp_url, metadata_uri, resource, server, challenge)}
    end
  end

  defp validate_challenge(nil, _url), do: :ok
  defp validate_challenge(%Challenge{parse_error: reason}, _url) when not is_nil(reason), do: error(reason)
  defp validate_challenge(%Challenge{mcp_url: url}, url), do: :ok
  defp validate_challenge(_, _url), do: error(:challenge_resource_mismatch)

  defp discover_resource(mcp_url, challenge, opts) do
    explicit = challenge && challenge.resource_metadata
    root = URL.origin(mcp_url) <> "/.well-known/oauth-protected-resource"
    urls = if explicit, do: [explicit], else: Enum.uniq([URL.well_known(mcp_url, "oauth-protected-resource"), root])

    with {:ok, document, uri} <- fetch_first(urls, opts),
         {:ok, resource} <- validate_schema(:resource, document),
         :ok <- validate_url(resource["resource"], opts) do
      allowed = if is_nil(explicit) and uri == root, do: [mcp_url, URL.origin(mcp_url)], else: [mcp_url]
      if resource["resource"] in allowed, do: {:ok, resource, uri}, else: error(:resource_mismatch)
    end
  end

  defp select_issuer([], _opts), do: error(:missing_authorization_server)

  defp select_issuer(issuers, opts) do
    case {Keyword.get(opts, :authorization_server), Enum.uniq(issuers)} do
      {nil, [issuer]} ->
        {:ok, issuer}

      {nil, issuers} ->
        error(:authorization_server_selection_required, %{authorization_servers: issuers})

      {issuer, issuers} ->
        if issuer in issuers, do: {:ok, issuer}, else: error(:unadvertised_authorization_server)
    end
  end

  defp validate_issuer(issuer, opts) do
    with :ok <- validate_url(issuer, opts) do
      if is_nil(URI.new!(issuer).query), do: :ok, else: error(:invalid_discovery_url)
    end
  end

  defp server_metadata_urls(issuer) do
    Enum.uniq([
      URL.well_known(issuer, "oauth-authorization-server"),
      URL.well_known(issuer, "openid-configuration"),
      String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"
    ])
  end

  defp validate_server(document, issuer, opts) do
    with {:ok, server} <- validate_schema(:server, document),
         true <- server["issuer"] == issuer,
         :ok <- validate_endpoints(server, opts) do
      {:ok, server}
    else
      false -> error(:issuer_mismatch)
      {:error, _} = error -> error
    end
  end

  defp validate_endpoints(server, opts) do
    ["authorization_endpoint", "token_endpoint", "registration_endpoint"]
    |> Enum.reject(&is_nil(server[&1]))
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case validate_url(server[key], opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_schema(kind, document) do
    result = if kind == :resource, do: resource_schema(document), else: server_schema(document)

    case result do
      {:ok, value} -> {:ok, value}
      {:error, _} -> error(if kind == :resource, do: :invalid_resource_metadata, else: :invalid_authorization_metadata)
    end
  end

  defp fetch_first([], _opts), do: error(:metadata_not_found)

  defp fetch_first([url | rest], opts) do
    with :ok <- validate_url(url, opts),
         :ok <- check_policy(url, opts),
         {:ok, response} <- fetch(url, opts) do
      case response do
        %{status: status} when status in [404, 405] ->
          fetch_first(rest, opts)

        %{status: 200, body: body} ->
          decode_metadata(body, url)

        %{status: status} ->
          error(:metadata_http_error, %{status: status})
      end
    end
  end

  defp decode_metadata(body, url) do
    case JSON.decode(body) do
      {:ok, document} when is_map(document) -> {:ok, document, url}
      _ -> error(:invalid_metadata_json)
    end
  end

  defp fetch(url, opts) do
    request = Finch.build(:get, url, [{"accept", "application/json"}])
    options = Keyword.merge(@default_http_options, Keyword.get(opts, :http_options, []))
    initial = %{status: nil, chunks: [], size: 0}

    case Finch.stream_while(request, Keyword.get(opts, :finch_name, Anubis.Finch), initial, &receive_metadata/2, options) do
      {:ok, %{size: size}} when size > @max_metadata_bytes ->
        error(:metadata_too_large)

      {:ok, response} ->
        {:ok, %{status: response.status, body: response.chunks |> Enum.reverse() |> IO.iodata_to_binary()}}

      {:error, reason, _response} ->
        error(:metadata_request_failed, %{original_reason: reason})
    end
  end

  defp receive_metadata({:status, status}, response), do: {:cont, %{response | status: status}}

  defp receive_metadata({:data, data}, response) do
    size = response.size + byte_size(data)

    if size > @max_metadata_bytes do
      {:halt, %{response | size: size}}
    else
      {:cont, %{response | size: size, chunks: [data | response.chunks]}}
    end
  end

  defp receive_metadata(_event, response), do: {:cont, response}

  defp validate_url(url, opts) do
    case URL.validate(url, opts) do
      :ok -> :ok
      {:error, reason} -> error(reason)
    end
  end

  defp check_policy(url, opts) do
    case Keyword.get(opts, :url_policy, fn _url -> :ok end).(url) do
      :ok -> :ok
      {:error, reason} -> error(:discovery_url_rejected, %{original_reason: reason})
    end
  end

  defp build_metadata(mcp_url, metadata_uri, resource, server, challenge) do
    %Metadata{
      mcp_url: mcp_url,
      resource: resource["resource"],
      resource_metadata_uri: metadata_uri,
      authorization_server: server["issuer"],
      authorization_endpoint: server["authorization_endpoint"],
      token_endpoint: server["token_endpoint"],
      registration_endpoint: server["registration_endpoint"],
      scopes_supported: resource["scopes_supported"] || [],
      grant_types_supported: server["grant_types_supported"] || ["authorization_code", "implicit"],
      response_types_supported: server["response_types_supported"],
      code_challenge_methods_supported: server["code_challenge_methods_supported"] || [],
      token_endpoint_auth_methods_supported: server["token_endpoint_auth_methods_supported"] || ["client_secret_basic"],
      client_id_metadata_document_supported: server["client_id_metadata_document_supported"] || false,
      challenge: challenge
    }
  end

  defp error(reason, data \\ %{}), do: {:error, Error.transport(reason, data)}
end
