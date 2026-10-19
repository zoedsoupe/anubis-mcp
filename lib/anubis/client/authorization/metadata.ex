defmodule Anubis.Client.Authorization.Metadata do
  @moduledoc """
  Validated discovery information for a host application's OAuth client.

  Include `resource` in both authorization and token requests (RFC 8707).
  `mcp_url` remains the endpoint to connect to, even if root metadata describes
  a broader resource. `scopes_supported` comes from the protected resource;
  a challenge's `scope` remains separate and takes precedence for that request.
  """

  alias Anubis.Client.Authorization.Challenge

  @type t :: %__MODULE__{
          mcp_url: String.t(),
          resource: String.t(),
          resource_metadata_uri: String.t(),
          authorization_server: String.t(),
          authorization_endpoint: String.t(),
          token_endpoint: String.t(),
          registration_endpoint: String.t() | nil,
          challenge: Challenge.t() | nil,
          scopes_supported: [String.t()],
          grant_types_supported: [String.t()],
          response_types_supported: [String.t()],
          code_challenge_methods_supported: [String.t()],
          token_endpoint_auth_methods_supported: [String.t()],
          client_id_metadata_document_supported: boolean()
        }
  @enforce_keys [
    :mcp_url,
    :resource,
    :resource_metadata_uri,
    :authorization_server,
    :authorization_endpoint,
    :token_endpoint
  ]
  defstruct [
    :mcp_url,
    :resource,
    :resource_metadata_uri,
    :authorization_server,
    :authorization_endpoint,
    :token_endpoint,
    :registration_endpoint,
    :challenge,
    scopes_supported: [],
    grant_types_supported: [],
    response_types_supported: [],
    code_challenge_methods_supported: [],
    token_endpoint_auth_methods_supported: [],
    client_id_metadata_document_supported: false
  ]
end
