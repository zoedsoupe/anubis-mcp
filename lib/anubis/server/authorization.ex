defmodule Anubis.Server.Authorization do
  @moduledoc """
  OAuth 2.1 resource server authorization support.

  Provides configuration, metadata building, and token validation primitives
  for securing MCP servers with bearer token authorization.

  ## Standards Implemented

    * RFC 6750 — Bearer Token Usage
    * RFC 9728 — Protected Resource Metadata
    * RFC 8707 — Resource Indicators (audience validation)
    * RFC 7662 — Token Introspection
    * RFC 7519 — JSON Web Token (JWT)

  ## Configuration

      use MyServer,
        authorization: [
          authorization_servers: ["https://auth.example.com"],
          resource: "https://api.example.com",
          realm: "mcp",
          scopes_supported: ["tools:read", "tools:write"],
          validator: {Anubis.Server.Authorization.JWTValidator,
            jwks_uri: "https://auth.example.com/.well-known/jwks.json"}
        ]

  ## Claims map

  After successful validation, a normalized claims map is stored in `Context.auth`:

      %{
        sub: "user-id",
        aud: "https://api.example.com",
        scope: "tools:read tools:write",
        scopes: ["tools:read", "tools:write"],
        exp: 1_234_567_890,
        iat: 1_234_567_800,
        client_id: "client-abc",
        raw_claims: %{}
      }
  """

  import Peri

  @type config :: %{
          authorization_servers: [String.t()],
          resource: String.t(),
          realm: String.t(),
          scopes_supported: [String.t()],
          validator: {module(), keyword()}
        }

  @type claims :: %{
          sub: String.t() | nil,
          aud: String.t() | [String.t()] | nil,
          scope: String.t() | nil,
          scopes: [String.t()],
          exp: integer() | nil,
          iat: integer() | nil,
          client_id: String.t() | nil,
          raw_claims: map()
        }

  defschema(:parse_config_schema, [
    {:authorization_servers, {:required, {:list, :string}}},
    {:resource, {:required, :string}},
    {:realm, {:string, {:default, "mcp"}}},
    {:scopes_supported, {{:list, :string}, {:default, []}}},
    {:validator, {:required, {:tuple, [:atom, {:list, :any}]}}}
  ])

  @doc """
  Parses and validates the authorization configuration keyword list.

  Raises `ArgumentError` if required fields are missing or invalid.

  ## Examples

      config = Authorization.parse_config!(
        authorization_servers: ["https://auth.example.com"],
        resource: "https://api.example.com",
        validator: {MyValidator, []}
      )
  """
  @spec parse_config!(keyword()) :: config()
  def parse_config!(opts) when is_list(opts) do
    config = parse_config_schema!(opts)
    Map.new(config)
  end

  @doc """
  Builds the RFC 9728 protected resource metadata map.

  ## Examples

      Authorization.build_resource_metadata(config)
      # => %{
      #      "resource" => "https://api.example.com",
      #      "authorization_servers" => ["https://auth.example.com"],
      #      "scopes_supported" => ["tools:read"],
      #      "bearer_methods_supported" => ["header"]
      #    }
  """
  @spec build_resource_metadata(config()) :: map()
  def build_resource_metadata(config) do
    %{
      "resource" => config.resource,
      "authorization_servers" => config.authorization_servers,
      "scopes_supported" => config.scopes_supported,
      "bearer_methods_supported" => ["header"]
    }
  end

  @doc """
  Builds the `WWW-Authenticate` header value for a 401 unauthorized response.

  Includes `resource_metadata` URL per RFC 9728.

  ## Examples

      Authorization.build_www_authenticate(config, :unauthorized)
      # => ~s(Bearer realm="mcp", resource_metadata="https://api.example.com/.well-known/oauth-protected-resource")
  """
  @spec build_www_authenticate(config(), :unauthorized | {:insufficient_scope, String.t()}) :: String.t()
  def build_www_authenticate(config, :unauthorized) do
    metadata_url = well_known_url(config.resource)
    ~s(Bearer realm="#{config.realm}", resource_metadata="#{metadata_url}")
  end

  def build_www_authenticate(config, {:insufficient_scope, required_scope}) do
    ~s(Bearer realm="#{config.realm}", error="insufficient_scope", scope="#{required_scope}")
  end

  @doc """
  Validates that the token `aud` claim matches the server's canonical resource URI.

  Returns `:ok` when the audience matches, `{:error, :invalid_audience}` otherwise.

  ## Examples

      Authorization.validate_audience(%{aud: "https://api.example.com"}, config)
      # => :ok

      Authorization.validate_audience(%{aud: "https://other.example.com"}, config)
      # => {:error, :invalid_audience}
  """
  @spec validate_audience(claims(), config()) :: :ok | {:error, :invalid_audience}
  def validate_audience(%{aud: aud}, config) when is_binary(aud) do
    if aud == config.resource, do: :ok, else: {:error, :invalid_audience}
  end

  def validate_audience(%{aud: aud_list}, config) when is_list(aud_list) do
    if config.resource in aud_list, do: :ok, else: {:error, :invalid_audience}
  end

  def validate_audience(_, _), do: {:error, :invalid_audience}

  @doc """
  Validates that the token has not expired.

  Compares `exp` against the current Unix timestamp.
  Returns `:ok` if not expired, `{:error, :token_expired}` otherwise.
  Tokens without `exp` are treated as non-expiring.

  ## Examples

      Authorization.validate_expiry(%{exp: future_timestamp})
      # => :ok
  """
  @spec validate_expiry(claims()) :: :ok | {:error, :token_expired | :invalid_expiry}
  def validate_expiry(%{exp: nil}), do: :ok

  def validate_expiry(%{exp: exp}) when is_integer(exp) and exp >= 0 do
    now = System.os_time(:second)
    if exp > now, do: :ok, else: {:error, :token_expired}
  end

  def validate_expiry(%{exp: _}), do: {:error, :invalid_expiry}

  def validate_expiry(_), do: :ok

  @doc """
  Validates that the claims contain all required scopes.

  Returns `:ok` when all `required` scopes are present in the claims,
  `{:error, {:insufficient_scope, required_scopes}}` otherwise.

  ## Examples

      Authorization.validate_scopes(%{scopes: ["tools:read", "tools:write"]}, ["tools:read"])
      # => :ok

      Authorization.validate_scopes(%{scopes: ["tools:read"]}, ["tools:write"])
      # => {:error, {:insufficient_scope, ["tools:write"]}}
  """
  @spec validate_scopes(claims(), [String.t()]) ::
          :ok | {:error, {:insufficient_scope, [String.t()]}}
  def validate_scopes(_claims, []), do: :ok

  def validate_scopes(%{scopes: granted}, required) when is_list(granted) do
    missing = Enum.reject(required, &(&1 in granted))

    if missing == [], do: :ok, else: {:error, {:insufficient_scope, missing}}
  end

  def validate_scopes(_, required), do: {:error, {:insufficient_scope, required}}

  @doc """
  Returns the canonical `/.well-known/oauth-protected-resource` URL for a resource URI.

  ## Examples

      Authorization.well_known_url("https://api.example.com")
      # => "https://api.example.com/.well-known/oauth-protected-resource"
  """
  @spec well_known_url(String.t()) :: String.t()
  def well_known_url(resource) when is_binary(resource) do
    uri = URI.parse(resource)
    base = URI.to_string(%{uri | path: nil, query: nil, fragment: nil})
    "#{base}/.well-known/oauth-protected-resource"
  end

  @doc """
  Normalizes raw claims (string-keyed map) into the canonical claims shape.

  Parses the `scope` string into a `scopes` list for convenient membership checks.
  If the raw claims already contain a `scopes` list (string- or atom-keyed), it is
  preserved as-is so custom validators that emit pre-normalized data are honored.
  """
  @spec normalize_claims(map()) :: claims()
  def normalize_claims(raw) when is_map(raw) do
    scope = raw["scope"] || raw[:scope]

    scopes =
      cond do
        is_list(raw["scopes"]) -> raw["scopes"]
        is_list(raw[:scopes]) -> raw[:scopes]
        is_binary(scope) -> String.split(scope, " ", trim: true)
        true -> []
      end

    %{
      sub: raw["sub"] || raw[:sub],
      aud: raw["aud"] || raw[:aud],
      scope: scope,
      scopes: scopes,
      exp: raw["exp"] || raw[:exp],
      iat: raw["iat"] || raw[:iat],
      client_id: raw["client_id"] || raw[:client_id],
      raw_claims: raw
    }
  end
end
