defmodule Anubis.Server.SessionTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.MCP.Message
  alias Anubis.Server.Registry
  alias Anubis.Server.Session

  require Message

  @moduletag capture_log: true

  describe "start_link/1" do
    test "starts a session with valid options" do
      transport_name = Registry.transport_name(StubServer, StubTransport)
      start_supervised!({StubTransport, name: transport_name})
      task_sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: task_sup})

      session_name = Registry.session_name(StubServer, "test-session")

      assert {:ok, pid} =
               Session.start_link(
                 session_id: "test-session",
                 server_module: StubServer,
                 name: session_name,
                 transport: [layer: StubTransport, name: transport_name],
                 task_supervisor: task_sup
               )

      assert Process.alive?(pid)
    end
  end

  describe "handle_call/3 for messages" do
    setup :initialized_server

    test "rejects requests when not initialized" do
      transport_name = Registry.transport_name(StubServer, StubTransport)
      task_sup = Registry.task_supervisor_name(StubServer)
      session_name = Registry.session_name(StubServer, "not_initialized")

      session =
        start_supervised!(
          {Session,
           session_id: "not_initialized",
           server_module: StubServer,
           name: session_name,
           transport: [layer: StubTransport, name: transport_name],
           task_supervisor: task_sup},
          id: :uninit_session
        )

      request = build_request("tools/list", 123)

      assert {:ok, _} =
               GenServer.call(session, {:mcp_request, request, %{}})
    end

    test "accept ping requests when not initialized" do
      transport_name = Registry.transport_name(StubServer, StubTransport)
      task_sup = Registry.task_supervisor_name(StubServer)
      session_name = Registry.session_name(StubServer, "ping_uninit")

      session =
        start_supervised!(
          {Session,
           session_id: "ping_uninit",
           server_module: StubServer,
           name: session_name,
           transport: [layer: StubTransport, name: transport_name],
           task_supervisor: task_sup},
          id: :ping_session
        )

      request = build_request("ping", 123)
      assert {:ok, _} = GenServer.call(session, {:mcp_request, request, %{}})
    end
  end

  describe "handle_cast/2 for notifications" do
    setup :initialized_server

    test "handles notifications", %{server: session} do
      notification =
        build_notification("notifications/cancelled", %{"requestId" => 1})

      assert :ok =
               GenServer.cast(session, {:mcp_notification, notification, %{}})
    end

    test "handles initialize notification", %{server: session} do
      notification = build_notification("notifications/initialized", %{})

      assert :ok =
               GenServer.cast(session, {:mcp_notification, notification, %{}})
    end
  end

  describe "send_notification/3" do
    setup :initialized_server

    test "sends notification to transport", %{server: session} do
      assert :ok =
               :info
               |> Anubis.Server.send_log_message("hello")
               |> then(fn _ ->
                 send(
                   session,
                   {:send_notification, "notifications/log/message", %{"level" => :info, "message" => "hello"}}
                 )

                 :ok
               end)
    end
  end

  describe "session expiration" do
    test "session expires after idle timeout" do
      transport_name = Registry.transport_name(StubServer, StubTransport)
      start_supervised!({StubTransport, name: transport_name})
      task_sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: task_sup})

      session_id = "test_session_#{System.unique_integer()}"
      session_name = Registry.session_name(StubServer, session_id)

      session =
        start_supervised!(
          {Session,
           session_id: session_id,
           server_module: StubServer,
           name: session_name,
           transport: [layer: StubTransport, name: transport_name],
           task_supervisor: task_sup,
           session_idle_timeout: 100},
          id: :expiry_session
        )

      init_msg =
        init_request("2025-03-26", %{"name" => "TestClient", "version" => "1.0.0"})

      assert {:ok, _} = GenServer.call(session, {:mcp_request, init_msg, %{}})

      init_notification = build_notification("notifications/initialized", %{})
      assert :ok = GenServer.cast(session, {:mcp_notification, init_notification, %{}})

      assert Process.alive?(session)

      Process.sleep(150)

      refute Process.alive?(session)
    end

    test "session timer resets on activity" do
      transport_name = Registry.transport_name(StubServer, StubTransport)
      start_supervised!({StubTransport, name: transport_name})
      task_sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: task_sup})

      session_id = "reset_session_#{System.unique_integer()}"
      session_name = Registry.session_name(StubServer, session_id)

      session =
        start_supervised!(
          {Session,
           session_id: session_id,
           server_module: StubServer,
           name: session_name,
           transport: [layer: StubTransport, name: transport_name],
           task_supervisor: task_sup,
           session_idle_timeout: 200},
          id: :reset_session
        )

      init_msg =
        init_request("2025-03-26", %{"name" => "TestClient", "version" => "1.0.0"})

      assert {:ok, _} = GenServer.call(session, {:mcp_request, init_msg, %{}})

      init_notification = build_notification("notifications/initialized", %{})
      assert :ok = GenServer.cast(session, {:mcp_notification, init_notification, %{}})

      for _ <- 1..3 do
        Process.sleep(100)
        ping = build_request("ping", %{}, System.unique_integer())
        assert {:ok, _} = GenServer.call(session, {:mcp_request, ping, %{}})
        assert Process.alive?(session)
      end

      Process.sleep(250)

      refute Process.alive?(session)
    end

    test "notifications reset expiry timer" do
      transport_name = Registry.transport_name(StubServer, StubTransport)
      start_supervised!({StubTransport, name: transport_name})
      task_sup = Registry.task_supervisor_name(StubServer)
      start_supervised!({Task.Supervisor, name: task_sup})

      session_id = "notif_session_#{System.unique_integer()}"
      session_name = Registry.session_name(StubServer, session_id)

      session =
        start_supervised!(
          {Session,
           session_id: session_id,
           server_module: StubServer,
           name: session_name,
           transport: [layer: StubTransport, name: transport_name],
           task_supervisor: task_sup,
           session_idle_timeout: 200},
          id: :notif_session
        )

      init_msg =
        init_request("2025-03-26", %{"name" => "TestClient", "version" => "1.0.0"})

      assert {:ok, _} = GenServer.call(session, {:mcp_request, init_msg, %{}})

      init_notification = build_notification("notifications/initialized", %{})
      assert :ok = GenServer.cast(session, {:mcp_notification, init_notification, %{}})

      for _ <- 1..3 do
        Process.sleep(100)

        notification =
          build_notification("notifications/message", %{
            "level" => "info",
            "data" => "test"
          })

        assert :ok =
                 GenServer.cast(
                   session,
                   {:mcp_notification, notification, %{}}
                 )

        assert Process.alive?(session)
      end

      Process.sleep(250)

      refute Process.alive?(session)
    end
  end

  describe "sampling requests" do
    setup context do
      context
      |> Map.put(:client_capabilities, %{"sampling" => %{}})
      |> initialized_server()
    end

    test "server can send sampling request to client", %{
      server: session,
      transport: transport
    } do
      :ok = StubTransport.set_test_pid(transport, self())

      messages = [
        %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}
      ]

      send(
        session,
        {:send_sampling_request,
         %{
           "messages" => messages,
           "systemPrompt" => "You are a helpful assistant",
           "maxTokens" => 100
         }, 30_000}
      )

      Process.sleep(10)

      assert_receive {:send_message, request_data}
      assert {:ok, [decoded]} = Message.decode(request_data)

      assert Message.is_request(decoded)
      assert decoded["method"] == "sampling/createMessage"
      assert decoded["params"]["messages"] == messages
      assert decoded["params"]["systemPrompt"] == "You are a helpful assistant"
      assert decoded["params"]["maxTokens"] == 100

      request_id = decoded["id"]

      response = %{
        "id" => request_id,
        "result" => %{
          "role" => "assistant",
          "content" => %{"type" => "text", "text" => "Hello! How can I help you?"},
          "model" => "test-model",
          "stopReason" => "endTurn"
        }
      }

      :ok = GenServer.cast(session, {:mcp_response, response, %{}})

      Process.sleep(10)

      state = :sys.get_state(session)
      assert state.frame.assigns.last_sampling_response == response["result"]
      assert state.frame.assigns.last_sampling_request_id == request_id
    end

    test "server handles sampling request timeout", %{
      server: session,
      transport: transport
    } do
      :ok = StubTransport.set_test_pid(transport, self())

      messages = [
        %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}
      ]

      send(session, {:send_sampling_request, %{"messages" => messages}, 30_000})

      Process.sleep(10)

      assert_receive {:send_message, _request_data}

      state = :sys.get_state(session)
      assert map_size(state.server_requests) == 1
    end

    test "server handles sampling error response", %{
      server: session,
      transport: transport
    } do
      :ok = StubTransport.set_test_pid(transport, self())

      messages = [
        %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}
      ]

      send(session, {:send_sampling_request, %{"messages" => messages}, 30_000})

      Process.sleep(10)

      assert_receive {:send_message, request_data}
      assert {:ok, [decoded]} = Message.decode(request_data)
      request_id = decoded["id"]

      error_response = %{
        "id" => request_id,
        "error" => %{
          "code" => -32_600,
          "message" => "Client doesn't support sampling"
        }
      }

      :ok =
        GenServer.cast(session, {:mcp_response, error_response, %{}})

      Process.sleep(10)

      state = :sys.get_state(session)
      assert map_size(state.server_requests) == 0
    end
  end
end
