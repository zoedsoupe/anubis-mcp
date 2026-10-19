defmodule Anubis.Client.StatelessE2ETest do
  use Anubis.MCP.Case, async: false

  # End-to-end over real HTTP: the client transport posts to a Plug.Cowboy
  # server running the real Streamable HTTP Plug, so the stateless headers are
  # validated for real by the stateless binding (pattern from the
  # authorization tests' Plug.Cowboy usage).

  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  defmodule GreetTool do
    @moduledoc false

    use Anubis.Server.Component, type: :tool

    alias Anubis.Server.Response

    schema do
      field :name, :string, required: true
    end

    @impl true
    def execute(%{name: name}, frame), do: {:reply, Response.text(Response.tool(), "Hello #{name}!"), frame}
  end

  defmodule DualEraServer do
    @moduledoc false

    use Anubis.Server,
      name: "stateless-e2e-dual",
      version: "1.0.0",
      capabilities: [:tools],
      protocol_versions: ["2026-07-28", "2025-11-25"]

    component(GreetTool, name: "greet")
  end

  defmodule LegacyOnlyServer do
    @moduledoc false

    use Anubis.Server,
      name: "stateless-e2e-legacy",
      version: "1.0.0",
      capabilities: [:tools],
      protocol_versions: ["2025-11-25"]

    component(GreetTool, name: "greet")
  end

  setup context do
    server = context[:server] || DualEraServer

    start_supervised!({server, transport: {:streamable_http, []}})

    ref = make_ref()

    start_supervised!(
      {Plug.Cowboy, scheme: :http, plug: {StreamableHTTPPlug, server: server}, options: [port: 0, ref: ref]}
    )

    url = "http://localhost:#{:ranch.get_port(ref)}/mcp"
    client_name = context[:client_name] || __MODULE__.Client

    {:ok, _supervisor} =
      Anubis.Client.start_link(
        name: client_name,
        transport: {:streamable_http, base_url: url, transport_opts: [protocols: [:http1]]},
        client_info: %{"name" => "E2EClient", "version" => "1.0.0"},
        capabilities: %{}
      )

    %{client: client_name}
  end

  @tag timeout: 15_000
  test "auto-detects the stateless era against a dual-era server", %{client: client} do
    assert :ok = Anubis.Client.await_ready(client, timeout: 10_000)
    assert Anubis.Client.get_era(client) == :stateless

    assert {:ok, response} = Anubis.Client.list_tools(client)
    assert %{"greet" => _} = Map.new(response.result["tools"], &{&1["name"], &1})

    assert {:ok, response} = Anubis.Client.call_tool(client, "greet", %{"name" => "Zoey"})
    assert [%{"type" => "text", "text" => "Hello Zoey!"}] = response.result["content"]

    # the stateless era has no session: no initialize ever ran, no id was minted
    transport_name = Module.concat(client, "Transport")
    state = :sys.get_state(transport_name)
    assert is_nil(state.session_id)
  end

  @tag timeout: 15_000, server: LegacyOnlyServer, client_name: __MODULE__.LegacyClient
  test "falls back to initialize against a legacy-only server", %{client: client} do
    assert :ok = Anubis.Client.await_ready(client, timeout: 10_000)
    assert Anubis.Client.get_era(client) == :legacy

    assert {:ok, response} = Anubis.Client.list_tools(client)
    assert %{"greet" => _} = Map.new(response.result["tools"], &{&1["name"], &1})
  end
end
