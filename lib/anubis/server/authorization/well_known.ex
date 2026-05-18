if Code.ensure_loaded?(Plug) do
  defmodule Anubis.Server.Authorization.WellKnown do
    @moduledoc """
    Plug serving the RFC 9728 protected resource metadata document.

    Responds to `GET /.well-known/oauth-protected-resource` with the JSON
    metadata document describing this resource server's OAuth 2.1 configuration.

    This plug is automatically handled by both
    `Anubis.Server.Transport.StreamableHTTP.Plug` and
    `Anubis.Server.Transport.SSE.Plug` when authorization is configured.
    It can also be mounted independently in a Phoenix router or Plug pipeline.

    ## Standalone Usage

        forward "/.well-known/oauth-protected-resource",
          to: Anubis.Server.Authorization.WellKnown,
          authorization_config: my_auth_config
    """

    @behaviour Plug

    import Plug.Conn

    alias Anubis.Server.Authorization

    @impl Plug
    def init(opts) do
      Keyword.fetch!(opts, :authorization_config)
    end

    @impl Plug
    def call(conn, auth_config) do
      metadata = Authorization.build_resource_metadata(auth_config)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(metadata))
    end
  end
end
