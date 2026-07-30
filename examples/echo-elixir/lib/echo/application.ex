defmodule Echo.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = build_children()

    opts = [strategy: :one_for_one, name: Echo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp build_children do
    base_children = [
      {Phoenix.PubSub, name: Echo.PubSub},
    ]

    transport_type = Application.get_env(:echo, :mcp_transport, :streamable_http)

    case transport_type do
      :stdio ->
        # For STDIO transport, we don't need the web endpoint
        base_children ++ [{EchoMCP.Server, transport: :stdio}]

      :streamable_http ->
        # For Streamable HTTP transport, we need the web endpoint
        base_children ++
          [
            EchoWeb.Endpoint,
            {EchoMCP.Server, transport: :streamable_http}
          ]
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    EchoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
