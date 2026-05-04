defmodule Anubis.MCP.Setup do
  @moduledoc false

  import Anubis.MCP.Assertions
  import ExUnit.Assertions, only: [assert: 1]
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Anubis.MCP.Builders
  alias Anubis.MCP.Message
  alias Anubis.Server.Registry
  alias Anubis.Server.Session
  alias Anubis.Server.Transport.STDIO

  require Message

  @doc """
  Awaits the next outbound MCP request matching `method` and returns its id.

  Drains forwarded `{:mcp_send, raw_json}` messages emitted by `MockTransport`
  (see `register_mock_transport_forwarding/0`) until one matches `method`.
  Returns `nil` on timeout.
  """
  def get_request_id(_client, method, timeout \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_get_request_id(method, deadline)
  end

  defp do_get_request_id(method, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:mcp_send, raw} ->
        case JSON.decode(raw) do
          {:ok, %{"method" => ^method, "id" => id}} -> id
          _ -> do_get_request_id(method, deadline)
        end
    after
      remaining -> nil
    end
  end

  @doc """
  Returns a `Mox.expect/3`-compatible lambda that forwards every outbound MCP
  send to `pid` as `{:mcp_send, raw_json}` and replies `:ok`. Use when a test
  needs the forward but no per-call assertion.

      expect(Anubis.MockTransport, :send_message, forwarder(self()))
  """
  def forwarder(pid) do
    fn _, message, _ ->
      send(pid, {:mcp_send, message})
      :ok
    end
  end

  def send_response(client, response) do
    {:ok, encoded} = Message.encode_response(response, response["id"])
    GenServer.cast(client, {:response, encoded})
  end

  def send_error(client, error_response) do
    {:ok, encoded} = Message.encode_error(error_response, error_response["id"])
    GenServer.cast(client, {:response, encoded})
  end

  def send_notification(client, notification) do
    {:ok, encoded} = Message.encode_notification(notification)
    GenServer.cast(client, {:response, encoded})
  end

  def initialize_client(client, opts \\ []) do
    server_capabilities =
      opts[:server_capabilities] ||
        %{
          "resources" => %{},
          "tools" => %{},
          "prompts" => %{}
        }

    GenServer.cast(client, :initialize)

    request_id = get_request_id(client, "initialize")
    assert request_id

    response =
      Builders.init_response(
        request_id,
        "2025-03-26",
        %{"name" => "TestServer", "version" => "1.0.0"},
        server_capabilities
      )

    send_response(client, response)

    sync_client(client)
    flush_mcp_sends()
  end

  @doc """
  Forces the client mailbox to drain by issuing a synchronous `:get_server_info`
  call. Replaces fixed `Process.sleep` after async casts.
  """
  def sync_client(client) do
    _ = GenServer.call(client, :get_server_info)
    :ok
  end

  @doc """
  Drains every pending `{:mcp_send, _}` forwarded message from the test pid
  mailbox. Called after `initialize_client/2` so the test body starts with a
  clean mailbox and `assert_receive` matches the message the test cares about.
  """
  def flush_mcp_sends do
    receive do
      {:mcp_send, _} -> flush_mcp_sends()
    after
      0 -> :ok
    end
  end

  def initialized_server(ctx) do
    session_id = ctx[:session_id] || "test-session-123"
    protocol_version = ctx[:protocol_version]
    capabilities = ctx[:client_capabilities]
    info = ctx[:client_info] || %{"name" => "TestClient", "version" => "1.0.0"}

    transport_name = Registry.transport_name(StubServer, StubTransport)
    transport = start_supervised!({StubTransport, name: transport_name})

    task_sup = Registry.task_supervisor_name(StubServer)
    start_supervised!({Task.Supervisor, name: task_sup})

    session_name = Registry.session_name(StubServer, session_id)

    session =
      start_supervised!(
        {Session,
         session_id: session_id,
         server_module: StubServer,
         name: session_name,
         transport: [layer: StubTransport, name: transport_name],
         task_supervisor: task_sup}
      )

    request = Builders.init_request(protocol_version, info, capabilities)
    assert {:ok, _} = GenServer.call(session, {:mcp_request, request, %{}})
    notification = Builders.build_notification("notifications/initialized", %{})
    assert :ok = GenServer.cast(session, {:mcp_notification, notification, %{}})

    Process.sleep(50)

    assert_server_initialized(session)

    :ok = StubTransport.clear(transport)

    Map.merge(ctx, %{
      transport: transport,
      server: session,
      session_id: session_id,
      server_module: StubServer
    })
  end

  def server_with_stdio_transport(ctx) do
    server_module = ctx[:server_module] || StubServer
    transport_name = Registry.transport_name(server_module, :stdio)
    task_sup = Registry.task_supervisor_name(server_module)
    start_supervised!({Task.Supervisor, name: task_sup})

    session_name = Registry.stdio_session_name(server_module)

    session =
      start_supervised!(
        {Session,
         session_id: "stdio",
         server_module: server_module,
         name: session_name,
         transport: [
           layer: STDIO,
           name: transport_name
         ],
         task_supervisor: task_sup}
      )

    io_device = start_supervised!({TestIODevice, []})

    transport =
      start_supervised!({STDIO, name: transport_name, server: server_module, io_device: io_device})

    Map.merge(ctx, %{server: session, transport: transport, io_device: io_device})
  end

  def initialized_client(context) do
    import Mox

    server_capabilities =
      context[:server_capabilities] ||
        %{
          "resources" => %{},
          "tools" => %{},
          "prompts" => %{}
        }

    client_info =
      context[:client_info] || %{"name" => "TestClient", "version" => "1.0.0"}

    client_capabilities = context[:client_capabilities] || %{}

    client =
      start_supervised!(%{
        id: Anubis.Client,
        start:
          {Anubis.Client, :start_link_server,
           [
             [
               transport: [layer: Anubis.MockTransport, name: MockTransport],
               client_info: client_info,
               capabilities: client_capabilities
             ]
           ]},
        restart: :temporary
      })

    allow(Anubis.MockTransport, self(), fn -> client end)
    initialize_client(client, server_capabilities: server_capabilities)

    Map.put(context, :client, client)
  end
end
