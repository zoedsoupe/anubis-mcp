if Code.ensure_loaded?(Plug) do
  defmodule Anubis.Server.Transport.WellKnown do
    @moduledoc """
    Plug that serves the RFC 9728 OAuth Protected Resource metadata document
    at `/.well-known/oauth-protected-resource`.

    Mount this plug at the root of your MCP server so the discovery endpoint is
    reachable even when the SSE or Streamable HTTP plugs are mounted under
    sub-paths such as `/sse` or `/mcp`.

    ## Usage

    Within a `Plug.Router`:

        forward "/.well-known/oauth-protected-resource",
          to: Anubis.Server.Transport.WellKnown,
          init_opts: [server: MyApp.MCPServer]

        forward "/sse", to: Anubis.Server.Transport.SSE.Plug,
          init_opts: [server: MyApp.MCPServer, mode: :sse]

    Within Phoenix:

        forward "/.well-known/oauth-protected-resource",
          Anubis.Server.Transport.WellKnown,
          server: MyApp.MCPServer

    Returns `404 Not Found` when the configured server has no authorization
    configured.
    """

    @behaviour Plug

    import Plug.Conn

    alias Anubis.Server.Authorization
    alias Anubis.Server.Supervisor, as: ServerSupervisor

    @impl Plug
    def init(opts) do
      server = Keyword.fetch!(opts, :server)
      %{server: server}
    end

    @impl Plug
    def call(conn, %{server: server}) do
      case ServerSupervisor.get_authorization_config(server) do
        nil ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(404, JSON.encode!(%{"error" => "not_found"}))
          |> halt()

        auth_config ->
          metadata = Authorization.build_resource_metadata(auth_config)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, JSON.encode!(metadata))
          |> halt()
      end
    end
  end
end
