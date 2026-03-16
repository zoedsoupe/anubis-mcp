defmodule Anubis.Server.Transport.SSE.PlugTest do
  use Anubis.MCP.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Anubis.MCP.Builders
  alias Anubis.MCP.Message
  alias Anubis.Server.Registry
  alias Anubis.Server.Session
  alias Anubis.Server.Transport.SSE
  alias Anubis.Server.Transport.SSE.Plug, as: SSEPlug

  @moduletag capture_log: true

  describe "init/1" do
    test "requires server option" do
      assert_raise KeyError, fn ->
        SSEPlug.init(mode: :sse)
      end
    end

    test "requires mode option" do
      assert_raise KeyError, fn ->
        SSEPlug.init(server: StubServer)
      end
    end

    test "mode must be :sse or :post" do
      assert_raise ArgumentError, ~r/mode to be either :sse or :post/, fn ->
        SSEPlug.init(server: StubServer, mode: :invalid)
      end
    end

    test "initializes with valid options" do
      opts = SSEPlug.init(server: StubServer, mode: :sse, timeout: 5000)

      assert %{
               transport: transport,
               mode: :sse,
               timeout: 5000
             } = opts

      assert transport == Registry.transport_name(StubServer, :sse)
    end
  end

  describe "SSE endpoint" do
    setup do
      name = Registry.transport_name(StubServer, :sse)

      {:ok, transport} =
        start_supervised({SSE, server: StubServer, name: name})

      sse_opts = SSEPlug.init(server: StubServer, mode: :sse)
      %{sse_opts: sse_opts, transport: transport}
    end

    test "GET request establishes SSE connection", %{transport: transport} do
      conn =
        :get
        |> conn("/sse")
        |> put_req_header("accept", "text/event-stream")

      assert conn.method == "GET"
      assert get_req_header(conn, "accept") == ["text/event-stream"]

      session_id = "test-session-123"
      assert :ok = SSE.register_sse_handler(transport, session_id)

      endpoint_url = SSE.get_endpoint_url(transport)
      assert endpoint_url == "/messages"

      capture_log(fn ->
        SSE.unregister_sse_handler(transport, session_id)
        Process.sleep(10)
      end)
    end

    test "GET request without SSE accept header returns error", %{sse_opts: sse_opts} do
      conn =
        :get
        |> conn("/sse")
        |> put_req_header("accept", "application/json")
        |> SSEPlug.call(sse_opts)

      assert conn.status == 406
      assert conn.resp_body =~ "Accept header must include text/event-stream"
    end

    test "non-GET request returns method not allowed", %{sse_opts: sse_opts} do
      conn =
        :post
        |> conn("/sse")
        |> SSEPlug.call(sse_opts)

      assert conn.status == 405
      assert conn.resp_body =~ "Method not allowed"
    end
  end

  describe "POST endpoint" do
    setup do
      registry_name = Registry.registry_name(StubServer)
      start_supervised!({Registry.Local, name: registry_name}, id: :sse_plug_registry)

      task_sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: task_sup})

      transport_name = Registry.transport_name(StubServer, StubTransport)
      start_supervised!({StubTransport, name: transport_name})

      session_id = "test-session"
      session_name = Registry.session_name(StubServer, session_id)

      {:ok, session_pid} =
        start_supervised(
          {Session,
           session_id: session_id,
           server_module: StubServer,
           name: session_name,
           transport: [layer: StubTransport, name: transport_name],
           task_supervisor: task_sup},
          id: :sse_post_session
        )

      Registry.Local.register_session(registry_name, session_id, session_pid)

      init_request =
        Builders.init_request(nil, %{"name" => "Test", "version" => "1.0"}, %{})

      {:ok, _} = GenServer.call(session_name, {:mcp_request, init_request, %{}})

      init_notif = Builders.build_notification("notifications/initialized", %{})
      GenServer.cast(session_name, {:mcp_notification, init_notif, %{}})
      Process.sleep(30)

      name = Registry.transport_name(StubServer, :sse)

      {:ok, transport} =
        start_supervised({SSE, server: StubServer, name: name})

      post_opts = SSEPlug.init(server: StubServer, mode: :post)
      %{post_opts: post_opts, transport: transport, session_id: session_id}
    end

    test "POST request with valid JSON returns response", %{
      post_opts: post_opts,
      transport: transport,
      session_id: session_id
    } do
      :ok = SSE.register_sse_handler(transport, session_id)

      request = build_request("ping", %{})
      {:ok, body} = Message.encode_request(request, 1)

      conn =
        :post
        |> conn("/messages", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-session-id", session_id)
        |> SSEPlug.call(post_opts)

      assert conn.status == 202
      assert conn.resp_body == "{}"

      capture_log(fn ->
        SSE.unregister_sse_handler(transport, session_id)
        Process.sleep(10)
      end)
    end

    test "POST request with notification returns 202", %{post_opts: post_opts, session_id: session_id} do
      notification =
        build_notification("notifications/message", %{
          "level" => "info",
          "data" => "test"
        })

      {:ok, body} = Message.encode_notification(notification)

      conn =
        :post
        |> conn("/messages", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-session-id", session_id)
        |> SSEPlug.call(post_opts)

      assert conn.status == 202
      assert conn.resp_body == "{}"
    end

    test "POST request with invalid JSON returns error", %{post_opts: post_opts} do
      conn =
        :post
        |> conn("/messages", "invalid json")
        |> put_req_header("content-type", "application/json")
        |> SSEPlug.call(post_opts)

      assert conn.status == 400

      {:ok, [response]} = Message.decode(conn.resp_body)
      assert Message.is_error(response)
      assert response["error"]["code"] == -32_700
    end

    test "non-POST request returns method not allowed", %{post_opts: post_opts} do
      conn =
        :get
        |> conn("/messages")
        |> SSEPlug.call(post_opts)

      assert conn.status == 405
      assert conn.resp_body =~ "Method not allowed"
    end
  end

  describe "session ID extraction" do
    setup do
      name = Registry.transport_name(StubServer, :sse)

      {:ok, transport} =
        start_supervised({SSE, server: StubServer, name: name})

      post_opts = SSEPlug.init(server: StubServer, mode: :post)
      %{post_opts: post_opts, transport: transport}
    end

    test "notification to unknown session returns error", %{post_opts: post_opts} do
      notification =
        build_notification("notifications/message", %{
          "level" => "info",
          "data" => "test"
        })

      {:ok, body} = Message.encode_notification(notification)

      conn =
        :post
        |> conn("/messages", body)
        |> put_req_header("x-session-id", "nonexistent-session")
        |> SSEPlug.call(post_opts)

      assert conn.status == 400
    end

    test "notification without session ID returns error", %{post_opts: post_opts} do
      notification =
        build_notification("notifications/message", %{
          "level" => "info",
          "data" => "test"
        })

      {:ok, body} = Message.encode_notification(notification)

      conn =
        :post
        |> conn("/messages", body)
        |> SSEPlug.call(post_opts)

      assert conn.status == 400
    end
  end
end
