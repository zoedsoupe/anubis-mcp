defmodule EchoWeb.Router do
  use EchoWeb, :router

  alias Anubis.Server.Transport.StreamableHTTP

  pipeline :mcp do
    plug :accepts, ["json", "event-stream"]
  end

  scope "/" do
    pipe_through :mcp

    forward "/mcp", StreamableHTTP.Plug, server: EchoMCP.Server
  end
end
