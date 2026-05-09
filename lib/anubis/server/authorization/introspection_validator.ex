defmodule Anubis.Server.Authorization.IntrospectionValidator do
  @moduledoc """
  Token validator using RFC 7662 Token Introspection.

  Validates opaque bearer tokens by POSTing them to an authorization server's
  introspection endpoint. Supports HTTP Basic authentication with client credentials.

  ## Configuration

      validator: {Anubis.Server.Authorization.IntrospectionValidator,
        introspection_endpoint: "https://auth.example.com/introspect",
        client_id: "my-client",
        client_secret: "my-secret"
      }

  ## Options

    * `:introspection_endpoint` — URL of the introspection endpoint (required)
    * `:client_id` — client ID for Basic authentication (optional)
    * `:client_secret` — client secret for Basic authentication (optional)
  """

  @behaviour Anubis.Server.Authorization.Validator

  use Anubis.Logging

  @impl true
  def validate_token(token, config) when is_binary(token) do
    opts = elem(config.validator, 1)
    endpoint = Keyword.fetch!(opts, :introspection_endpoint)

    headers = build_headers(opts)
    body = URI.encode_query(%{"token" => token})

    request =
      Finch.build(
        :post,
        endpoint,
        headers,
        body
      )

    case Finch.request(request, Anubis.Finch) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        parse_introspection_response(body)

      {:ok, %Finch.Response{status: status}} ->
        Logging.server_event("introspection_http_error", %{status: status}, level: :warning)
        {:error, {:introspection_error, status}}

      {:error, reason} ->
        Logging.server_event("introspection_request_failed", %{reason: inspect(reason)}, level: :error)
        {:error, {:introspection_failed, reason}}
    end
  end

  defp build_headers(opts) do
    base_headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case {Keyword.get(opts, :client_id), Keyword.get(opts, :client_secret)} do
      {id, secret} when is_binary(id) and is_binary(secret) ->
        credentials = Base.encode64("#{id}:#{secret}")
        [{"authorization", "Basic #{credentials}"} | base_headers]

      _ ->
        base_headers
    end
  end

  defp parse_introspection_response(body) do
    case JSON.decode(body) do
      {:ok, %{"active" => true} = claims} ->
        {:ok, claims}

      {:ok, %{"active" => false}} ->
        {:error, :token_inactive}

      {:ok, _} ->
        {:error, :token_inactive}

      {:error, reason} ->
        Logging.server_event("introspection_parse_error", %{reason: inspect(reason)}, level: :error)
        {:error, :invalid_introspection_response}
    end
  end
end
