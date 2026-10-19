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

  describe "mid-operation -32022" do
    test "re-sends the request once with the negotiated version, on the same id" do
      client = setup_client(%{})
      discover_client(client, server_capabilities: @server_capabilities)

      # D5: a cached version can be rejected later by a server config change or
      # mixed pods. With a single registered stateless version the retry only
      # diverges when the client's cached version is behind, so the cached
      # version is rewound to a legacy one to simulate the rejection.
      state = :sys.get_state(client)
      :sys.replace_state(client, fn state -> %{state | protocol_version: "2025-06-18"} end)

      test_pid = self()

      FakeTransport.expect_send(FakeTransport, fn message ->
        send(test_pid, {:first, JSON.decode!(message)})
        :ok
      end)

      FakeTransport.expect_send(FakeTransport, fn message ->
        send(test_pid, {:retry, JSON.decode!(message)})
        :ok
      end)

      task = Task.async(fn -> Anubis.Client.list_tools(client) end)

      assert_receive {:first, first}, 500
      refute Map.has_key?(first["params"]["_meta"] || %{}, @version_key)

      send_error(
        client,
        Builders.build_error(-32_022, "Unsupported protocol version", first["id"], %{"supported" => ["2026-07-28"]})
      )

      assert_receive {:retry, retry}, 500
      assert retry["id"] == first["id"]
      assert retry["params"]["_meta"][@version_key] == "2026-07-28"

      send_response(client, Builders.tools_list_response(first["id"], []))
      assert {:ok, _} = Task.await(task)

      assert Anubis.Client.get_era(client) == :stateless
    end

    test "a second -32022 surfaces the error" do
      client = setup_client(%{})
      discover_client(client, server_capabilities: @server_capabilities)

      state = :sys.get_state(client)
      :sys.replace_state(client, fn state -> %{state | protocol_version: "2025-06-18"} end)

      test_pid = self()

      FakeTransport.expect_send(FakeTransport, fn message ->
        send(test_pid, {:first, JSON.decode!(message)})
        :ok
      end)

      FakeTransport.expect_send(FakeTransport, fn message ->
        send(test_pid, {:retry, JSON.decode!(message)})
        :ok
      end)

      task = Task.async(fn -> Anubis.Client.list_tools(client) end)

      assert_receive {:first, first}, 500

      send_error(
        client,
        Builders.build_error(-32_022, "Unsupported protocol version", first["id"], %{"supported" => ["2026-07-28"]})
      )

      assert_receive {:retry, retry}, 500

      send_error(
        client,
        Builders.build_error(-32_022, "Unsupported protocol version", retry["id"], %{"supported" => ["2026-07-28"]})
      )

      assert {:error, error} = Task.await(task)
      assert error.code == -32_022

      flush_mcp_sends()
      refute_receive {:mcp_send, _}, 200
    end

    test "a -32022 listing only the current version surfaces the error with no retry" do
      client = setup_client(%{})
      discover_client(client, server_capabilities: @server_capabilities)

      task = Task.async(fn -> Anubis.Client.list_tools(client) end)

      request_id = get_request_id(client, "tools/list")
      assert request_id

      send_error(
        client,
        Builders.build_error(-32_022, "Unsupported protocol version", request_id, %{"supported" => ["2026-07-28"]})
      )

      assert {:error, error} = Task.await(task)
      assert error.code == -32_022

      flush_mcp_sends()
      refute_receive {:mcp_send, _}, 200
    end

    test "a -32022 with no intersection surfaces the error with no retry" do
      client = setup_client(%{})
      discover_client(client, server_capabilities: @server_capabilities)

      task = Task.async(fn -> Anubis.Client.list_tools(client) end)

      request_id = get_request_id(client, "tools/list")
      assert request_id

      send_error(
        client,
        Builders.build_error(-32_022, "Unsupported protocol version", request_id, %{"supported" => ["9999-01-01"]})
      )

      assert {:error, _} = Task.await(task)

      flush_mcp_sends()
      refute_receive {:mcp_send, _}, 200
    end

    test "a -32022 in the legacy era is not retried" do
      client = setup_client(%{})
      initialize_client(client, server_capabilities: @server_capabilities)

      task = Task.async(fn -> Anubis.Client.list_tools(client) end)

      request_id = get_request_id(client, "tools/list")
      assert request_id

      send_error(
        client,
        Builders.build_error(-32_022, "Unsupported protocol version", request_id, %{"supported" => ["2026-07-28"]})
      )

      assert {:error, error} = Task.await(task)
      assert error.code == -32_022

      flush_mcp_sends()
      refute_receive {:mcp_send, _}, 200
    end
  end
end
