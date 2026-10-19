defmodule Anubis.Client.StatelessRequestsTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.MCP.Builders

  @server_capabilities %{"tools" => %{}, "prompts" => %{}, "resources" => %{}}
  @version_key "io.modelcontextprotocol/protocolVersion"

  setup do
    {:ok, transport} = FakeTransport.start(forward_to: self())

    on_exit(fn ->
      try do
        FakeTransport.verify!(FakeTransport)
      after
        GenServer.stop(transport)
      end
    end)

    :ok
  end

  describe "stateless requests" do
    test "carry the era _meta with the negotiated version, capabilities and clientInfo" do
      client = setup_client(%{})
      discover_client(client, server_capabilities: @server_capabilities)

      test_pid = self()

      FakeTransport.expect_send(FakeTransport, fn message ->
        send(test_pid, {:mcp_send, message})

        decoded = JSON.decode!(message)
        assert decoded["method"] == "tools/list"

        meta = decoded["params"]["_meta"]
        assert meta[@version_key] == "2026-07-28"
        assert meta["io.modelcontextprotocol/clientCapabilities"] == %{}
        assert meta["io.modelcontextprotocol/clientInfo"] == %{"name" => "TestClient", "version" => "1.0.0"}

        :ok
      end)

      task = Task.async(fn -> Anubis.Client.list_tools(client) end)

      request_id = get_request_id(client, "tools/list")
      assert request_id

      send_response(client, Builders.tools_list_response(request_id, []))
      assert {:ok, _} = Task.await(task)
    end

    test "merge the progress token into the same _meta" do
      client = setup_client(%{})
      discover_client(client, server_capabilities: @server_capabilities)

      test_pid = self()

      FakeTransport.expect_send(FakeTransport, fn message ->
        send(test_pid, {:mcp_send, message})

        decoded = JSON.decode!(message)
        meta = decoded["params"]["_meta"]
        assert meta["progressToken"] == "tok-1"
        assert meta[@version_key] == "2026-07-28"

        :ok
      end)

      task = Task.async(fn -> Anubis.Client.list_tools(client, progress: [token: "tok-1"]) end)

      request_id = get_request_id(client, "tools/list")
      assert request_id

      send_response(client, Builders.tools_list_response(request_id, []))
      assert {:ok, _} = Task.await(task)
    end

    test "carry the era _meta on tools/call, resources/read and prompts/get" do
      client = setup_client(%{})
      discover_client(client, server_capabilities: @server_capabilities)

      test_pid = self()

      FakeTransport.expect_send(FakeTransport, fn message ->
        send(test_pid, {:mcp_send, message})

        decoded = JSON.decode!(message)

        case decoded["method"] do
          "tools/call" ->
            assert decoded["params"]["name"] == "greet"
            assert decoded["params"]["_meta"][@version_key] == "2026-07-28"

          "resources/read" ->
            assert decoded["params"]["uri"] == "config://test"
            assert decoded["params"]["_meta"][@version_key] == "2026-07-28"

          "prompts/get" ->
            assert decoded["params"]["name"] == "beauty"
            assert decoded["params"]["_meta"][@version_key] == "2026-07-28"

          other ->
            flunk("unexpected method #{other}")
        end

        :ok
      end)

      task = Task.async(fn -> Anubis.Client.call_tool(client, "greet", %{"name" => "Zoey"}) end)

      request_id = get_request_id(client, "tools/call")
      assert request_id

      send_response(client, Builders.tools_call_response(request_id, [%{"type" => "text", "text" => "hi"}]))
      assert {:ok, _} = Task.await(task)

      task = Task.async(fn -> Anubis.Client.read_resource(client, "config://test") end)

      request_id = get_request_id(client, "resources/read")
      assert request_id

      send_response(client, Builders.resources_read_response(request_id, []))
      assert {:ok, _} = Task.await(task)

      task = Task.async(fn -> Anubis.Client.get_prompt(client, "beauty") end)

      request_id = get_request_id(client, "prompts/get")
      assert request_id

      send_response(client, Builders.prompts_get_response(request_id, []))
      assert {:ok, _} = Task.await(task)
    end

    test "carry merged capabilities on the next request's _meta" do
      client = setup_client(%{})
      discover_client(client, server_capabilities: @server_capabilities)

      assert %{"sampling" => %{}} = Anubis.Client.merge_capabilities(client, %{"sampling" => %{}})

      test_pid = self()

      FakeTransport.expect_send(FakeTransport, fn message ->
        send(test_pid, {:mcp_send, message})

        decoded = JSON.decode!(message)
        assert decoded["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"] == %{"sampling" => %{}}

        :ok
      end)

      task = Task.async(fn -> Anubis.Client.list_tools(client) end)

      request_id = get_request_id(client, "tools/list")
      assert request_id

      send_response(client, Builders.tools_list_response(request_id, []))
      assert {:ok, _} = Task.await(task)
    end
  end

  describe "methods removed by the stateless era" do
    test "are refused with a method_not_found error naming the era" do
      client = setup_client(%{})
      discover_client(client, server_capabilities: @server_capabilities)

      assert {:error, error} = Anubis.Client.ping(client)
      assert error.reason == :method_not_found
      assert error.data.era == :stateless
      assert error.data.method == "ping"

      assert {:error, error} = Anubis.Client.set_log_level(client, "debug")
      assert error.data.era == :stateless
      assert error.data.method == "logging/setLevel"

      assert {:error, error} = Anubis.Client.subscribe_resource(client, "config://test")
      assert error.data.era == :stateless
      assert error.data.method == "resources/subscribe"

      assert {:error, error} = Anubis.Client.unsubscribe_resource(client, "config://test")
      assert error.data.era == :stateless
      assert error.data.method == "resources/unsubscribe"

      flush_mcp_sends()
      refute_receive {:mcp_send, _}, 200
    end

    test "still work on a legacy client" do
      client = setup_client(%{})
      initialize_client(client, server_capabilities: @server_capabilities)

      task = Task.async(fn -> Anubis.Client.ping(client) end)

      request_id = get_request_id(client, "ping")
      assert request_id

      send_response(client, Builders.ping_response(request_id))
      assert :pong = Task.await(task)

      assert Anubis.Client.get_era(client) == :legacy
    end
  end

  test "add_root sends no notifications/roots/list_changed in the stateless era" do
    client = setup_client(%{})
    discover_client(client, server_capabilities: @server_capabilities)

    assert :ok = Anubis.Client.add_root(client, "file:///tmp/project")
    sync_client(client)
    flush_mcp_sends()

    refute_receive {:mcp_send, _}, 200
  end
end
