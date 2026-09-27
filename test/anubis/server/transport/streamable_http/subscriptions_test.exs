defmodule Anubis.Server.Transport.StreamableHTTP.SubscriptionsTest do
  use Anubis.MCP.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers
  alias Anubis.Server.Handlers.Subscriptions
  alias Anubis.Server.Registry
  alias Anubis.Server.Supervisor, as: ServerSupervisor
  alias Anubis.Server.Transport.StreamableHTTP
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  @moduletag capture_log: true

  @version "2026-07-28"
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @watched "notes:///1"
  @unwatched "notes:///2"

  defmodule ListeningServer do
    @moduledoc false

    use Anubis.Server,
      name: "listening-server",
      version: "1.0.0",
      capabilities: [{:tools, list_changed?: true}, {:resources, subscribe?: true}],
      protocol_versions: ["2026-07-28", "2025-11-25"]

    @impl true
    def init(_client_info, frame) do
      send(frame.assigns.test_pid, {:listening_session, self()})
      {:ok, Frame.assign(frame, :initialized, true)}
    end

    @impl true
    def handle_info({:resource_changed, uri}, frame) do
      Anubis.Server.send_resource_updated(uri)
      {:noreply, frame}
    end

    def handle_info({:whoami, pid}, frame) do
      context = frame.context
      send(pid, {:whoami, context.client_info["name"], context.headers["mcp-method"], context.protocol_version})
      {:noreply, frame}
    end

    def handle_info(:tools_changed, frame) do
      Anubis.Server.send_tools_list_changed()
      {:noreply, frame}
    end

    def handle_info(:prompts_changed, frame) do
      Anubis.Server.send_prompts_list_changed()
      {:noreply, frame}
    end

    def handle_info(:log, frame) do
      Anubis.Server.send_log_message("info", "not for the listen stream")
      {:noreply, frame}
    end
  end

  setup do
    server = ListeningServer

    task_sup = Registry.task_supervisor_name(server)
    start_supervised!({Task.Supervisor, name: task_sup})

    registry_name = Registry.registry_name(server)
    start_supervised!({Registry.Local, name: registry_name})
    start_supervised!({Elixir.Registry, keys: :unique, name: Registry.naming_registry_name(registry_name)})

    session_sup = Registry.session_supervisor_name(server)
    start_supervised!({DynamicSupervisor, name: session_sup, strategy: :one_for_one})

    http_transport = Registry.transport_name(server, :streamable_http)

    transport =
      start_supervised!(
        {StreamableHTTP, server: server, name: http_transport, task_supervisor: task_sup, keepalive: false}
      )

    :persistent_term.put({ServerSupervisor, server, :session_config}, %{
      server_module: server,
      registry_mod: Registry.Local,
      transport: [layer: StreamableHTTP, name: http_transport],
      session_idle_timeout: nil,
      timeout: 30_000,
      task_supervisor: task_sup
    })

    on_exit(fn -> :persistent_term.erase({ServerSupervisor, server, :session_config}) end)

    %{opts: StreamableHTTPPlug.init(server: server), transport: transport, session_sup: session_sup}
  end

  describe "subscriptions/listen" do
    test "acknowledges only what the server honors, then streams it with the subscription id", %{opts: opts} do
      filter = %{
        "toolsListChanged" => true,
        "promptsListChanged" => true,
        "resourceSubscriptions" => [@watched]
      }

      {stream, session} = open(opts, filter)

      send(session, {:resource_changed, @watched})
      send(session, {:resource_changed, @unwatched})
      send(session, :tools_changed)
      send(session, :prompts_changed)
      send(session, :log)
      drain(session)

      messages = close(stream)

      assert [ack | rest] = messages
      assert ack["method"] == "notifications/subscriptions/acknowledged"
      assert ack["params"]["notifications"] == %{"toolsListChanged" => true, "resourceSubscriptions" => [@watched]}

      {notifications, [final]} = Enum.split(rest, -1)
      assert final["result"]["resultType"] == "complete"

      assert notifications |> Enum.map(&{&1["method"], &1["params"]["uri"]}) |> Enum.sort() == [
               {"notifications/resources/updated", @watched},
               {"notifications/tools/list_changed", nil}
             ]

      for message <- messages do
        meta = message["params"]["_meta"] || message["result"]["_meta"]
        assert meta[@subscription_id_key] == 7
      end
    end

    test "ends with a completion result for the listen request", %{opts: opts} do
      {stream, _session} = open(opts, %{"toolsListChanged" => true})

      assert %{"id" => 7, "result" => %{"resultType" => "complete"}} = List.last(close(stream))
    end

    test "ends gracefully when the session stops", %{opts: opts} do
      {stream, session} = open(opts, %{"toolsListChanged" => true})

      GenServer.stop(session, :shutdown)

      assert %{"id" => 7, "result" => %{"resultType" => "complete"}} =
               stream |> Task.await(2_000) |> decode_chunks() |> List.last()
    end

    test "stops the session when the client goes away", %{opts: opts, session_sup: session_sup} do
      {stream, session} = open(opts, %{"toolsListChanged" => true})
      ref = Process.monitor(session)

      Process.unlink(stream.pid)
      Process.exit(stream.pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^session, _reason}, 2_000
      assert DynamicSupervisor.count_children(session_sup).active == 0
    end

    test "registers the stream with the plug's subscriber metadata", %{transport: transport} do
      opts = StreamableHTTPPlug.init(server: ListeningServer, subscriber_metadata: fn _conn -> %{tenant: "acme"} end)

      {stream, _session} = open(opts, %{"toolsListChanged" => true})

      assert StreamableHTTP.handler_count(transport, &(&1[:tenant] == "acme")) == 1

      close(stream)
    end

    test "is refused with a 406 when the client does not accept a stream", %{opts: opts, session_sup: session_sup} do
      conn =
        :post
        |> conn("/", listen_body(%{"toolsListChanged" => true}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-protocol-version", @version)
        |> put_req_header("mcp-method", "subscriptions/listen")
        |> StreamableHTTPPlug.call(opts)

      assert conn.status == 406
      assert %{"id" => 7, "error" => %{"code" => -32_600}} = JSON.decode!(conn.resp_body)
      assert DynamicSupervisor.count_children(session_sup).active == 0
    end

    test "keeps the session with no idle expiry while it listens", %{opts: opts} do
      {stream, session} = open(opts, %{"toolsListChanged" => true})

      assert :sys.get_state(session).expiry_timer == nil

      close(stream)
    end

    test "callbacks after the listen reply still see the listen request's context", %{opts: opts} do
      {stream, session} = open(opts, %{"toolsListChanged" => true})

      send(session, {:whoami, self()})

      assert_receive {:whoami, "Listener", "subscriptions/listen", @version}, 2_000

      close(stream)
    end

    test "runs init/2 for the listen request, as for any stateless request", %{opts: opts} do
      {stream, session} = open(opts, %{"toolsListChanged" => true})

      assert :sys.get_state(session).frame.assigns.initialized

      close(stream)
    end
  end

  describe "the honored filter" do
    test "leaves out what the server does not declare" do
      request = %{
        "method" => "subscriptions/listen",
        "params" => %{"notifications" => %{"toolsListChanged" => true, "resourceSubscriptions" => [@watched]}}
      }

      assert {:reply, %{"notifications" => honored}, frame} =
               Subscriptions.handle_listen(request, Frame.new(), StubServer)

      assert honored == %{}
      refute Frame.resource_subscribed?(frame, @watched)
    end

    test "is not served in the handshake era" do
      request = %{"method" => "subscriptions/listen", "params" => %{"notifications" => %{"toolsListChanged" => true}}}

      assert {:error, %Error{code: -32_601}, _frame} = Handlers.handle(request, ListeningServer, Frame.new())
    end
  end

  defp open(opts, filter) do
    test_pid = self()

    body = listen_body(filter)

    stream =
      Task.async(fn ->
        :post
        |> conn("/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", @version)
        |> put_req_header("mcp-method", "subscriptions/listen")
        |> assign(:test_pid, test_pid)
        |> StreamableHTTPPlug.call(opts)
      end)

    assert_receive {:listening_session, session}, 2_000
    await_listening(session)
    {stream, session}
  end

  # The session answers the listen request asynchronously; once nothing is in
  # flight the acknowledgment is on its way and the filter is on the frame.
  defp await_listening(session) do
    if :sys.get_state(session).in_flight, do: await_listening(session), else: :ok
  end

  # A notification leaves the session through messages it sends itself, so the
  # session is drained, not merely synced, before the stream is closed.
  defp drain(session) do
    :sys.get_state(session)

    case Process.info(session, :message_queue_len) do
      {:message_queue_len, 0} -> :ok
      _pending -> drain(session)
    end
  end

  defp listen_body(filter) do
    JSON.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "subscriptions/listen",
      "params" => %{
        "notifications" => filter,
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientInfo" => %{"name" => "Listener", "version" => "1.0.0"},
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    })
  end

  defp close(stream) do
    send(stream.pid, :close_sse)
    stream |> Task.await(2_000) |> decode_chunks()
  end

  defp decode_chunks(%Plug.Conn{adapter: {Plug.Adapters.Test.Conn, %{chunks: chunks}}}) do
    for "data: " <> data <- String.split(chunks, "\n"), do: JSON.decode!(data)
  end
end
