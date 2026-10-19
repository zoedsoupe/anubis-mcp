defmodule Anubis.Client.EraDetectionTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.Client.Authorization.Challenge
  alias Anubis.MCP.Builders

  @server_capabilities %{"tools" => %{}, "prompts" => %{}, "resources" => %{}}
  @server_info %{"name" => "TestServer", "version" => "1.0.0"}

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

  describe ":connect probe" do
    test "sends server/discover with the stateless _meta and goes ready on the result" do
      client = setup_client(%{})

      GenServer.cast(client, :connect)

      assert_receive {:mcp_send, raw}, 500
      decoded = JSON.decode!(raw)
      assert decoded["method"] == "server/discover"

      meta = decoded["params"]["_meta"]
      assert meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
      assert meta["io.modelcontextprotocol/clientCapabilities"] == %{}
      assert meta["io.modelcontextprotocol/clientInfo"] == %{"name" => "TestClient", "version" => "1.0.0"}
      refute Map.has_key?(meta, "progressToken")

      send_response(client, Builders.discover_response(decoded["id"], ["2026-07-28"], @server_capabilities, @server_info))
      sync_client(client)

      assert :ok = Anubis.Client.await_ready(client)
      assert Anubis.Client.get_era(client) == :stateless
      assert Anubis.Client.get_server_capabilities(client) == @server_capabilities
      assert Anubis.Client.get_server_info(client) == @server_info

      # the stateless era has no handshake: no notifications/initialized ever goes out
      flush_mcp_sends()
      refute_receive {:mcp_send, _}, 200
    end

    test "falls back to initialize on -32601 and lands in the legacy era" do
      client = setup_client(%{})

      reject_probe(client)

      request_id = get_request_id(client, "initialize")
      assert request_id

      send_response(client, Builders.init_response(request_id, "2025-03-26", @server_info, @server_capabilities))
      sync_client(client)

      assert Anubis.Client.get_era(client) == :legacy
      assert :ok = Anubis.Client.await_ready(client)
    end

    test "re-probes with the negotiated version on -32022 with a known supported version" do
      client = setup_client(%{})

      GenServer.cast(client, :connect)

      probe_id = get_request_id(client, "server/discover")
      assert probe_id

      send_error(
        client,
        Builders.build_error(-32_022, "Unsupported protocol version", probe_id, %{"supported" => ["2026-07-28"]})
      )

      assert_receive {:mcp_send, raw}, 500
      decoded = JSON.decode!(raw)
      assert decoded["method"] == "server/discover"
      assert decoded["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"

      send_response(client, Builders.discover_response(decoded["id"], ["2026-07-28"], @server_capabilities))
      sync_client(client)

      assert Anubis.Client.get_era(client) == :stateless
      assert :ok = Anubis.Client.await_ready(client)
    end

    test "falls back to initialize on -32022 with an empty intersection" do
      client = setup_client(%{})

      GenServer.cast(client, :connect)

      probe_id = get_request_id(client, "server/discover")
      assert probe_id

      send_error(
        client,
        Builders.build_error(-32_022, "Unsupported protocol version", probe_id, %{"supported" => ["9999-01-01"]})
      )

      request_id = get_request_id(client, "initialize")
      assert request_id
    end

    test "an authorization challenge is terminal and preserved for Authorization.discover" do
      challenge = Challenge.from_response("https://example.com/mcp", 401, [])
      FakeTransport.expect_send(FakeTransport, fn _message -> {:error, {:authorization_required, challenge}} end)

      client = setup_client(%{})
      GenServer.cast(client, :connect)
      sync_client(client)

      assert {:error, error} = Anubis.Client.await_ready(client)
      assert error.data.original_reason == {:authorization_required, challenge}
      assert Process.alive?(client)
      assert :sys.get_state(client).pending_requests == %{}
    end

    test "a probe timeout falls back to initialize" do
      client = setup_client(%{}, timeout: 100)

      GenServer.cast(client, :connect)

      assert get_request_id(client, "server/discover")

      # the probe times out and the fallback initialize goes out
      request_id = get_request_id(client, "initialize")
      assert request_id
    end

    test "a probe send failure falls back, and a failing fallback initialize stops the client" do
      FakeTransport.expect_send(FakeTransport, fn _message -> {:error, :port_dead} end)
      FakeTransport.expect_send(FakeTransport, fn _message -> {:error, :port_dead} end)

      client = setup_client(%{})
      monitor = Process.monitor(client)

      GenServer.cast(client, :connect)

      assert_receive {:DOWN, ^monitor, :process, ^client, _reason}, 500
    end
  end

  describe "era lifecycle" do
    test "get_era/1 reports each stage" do
      client = setup_client(%{})
      assert Anubis.Client.get_era(client) == :detecting

      GenServer.cast(client, :connect)
      probe_id = get_request_id(client, "server/discover")
      assert probe_id
      sync_client(client)
      assert Anubis.Client.get_era(client) == :connecting

      send_error(client, Builders.build_error(-32_601, "Method not found", probe_id))

      request_id = get_request_id(client, "initialize")
      assert request_id

      send_response(client, Builders.init_response(request_id, "2025-03-26", @server_info, @server_capabilities))
      sync_client(client)
      assert Anubis.Client.get_era(client) == :legacy
    end

    test "get_era/1 reports the stateless stage after a discover result" do
      client = setup_client(%{})
      discover_client(client)

      assert Anubis.Client.get_era(client) == :stateless
    end
  end

  describe ":initialize cast" do
    test "is ignored on a stateless client" do
      client = setup_client(%{})
      discover_client(client)

      GenServer.cast(client, :initialize)
      sync_client(client)
      flush_mcp_sends()

      refute_receive {:mcp_send, _}, 200
      assert Anubis.Client.get_era(client) == :stateless
    end

    test "drops a pending probe and runs the legacy handshake; the late probe answer is ignored" do
      client = setup_client(%{})

      GenServer.cast(client, :connect)
      probe_id = get_request_id(client, "server/discover")
      assert probe_id

      GenServer.cast(client, :initialize)

      request_id = get_request_id(client, "initialize")
      assert request_id

      state = :sys.get_state(client)
      refute Enum.any?(state.pending_requests, fn {_id, request} -> request.method == "server/discover" end)

      send_response(client, Builders.init_response(request_id, "2025-03-26", @server_info, @server_capabilities))
      sync_client(client)
      assert Anubis.Client.get_era(client) == :legacy

      # the late probe answer must not flip an initialized legacy client
      send_response(client, Builders.discover_response(probe_id, ["2026-07-28"], @server_capabilities))
      sync_client(client)

      assert Anubis.Client.get_era(client) == :legacy
    end

    test "re-connect after a failed initialize re-probes" do
      client = setup_client(%{})

      GenServer.cast(client, :connect)
      probe_id = get_request_id(client, "server/discover")
      assert probe_id

      # an empty intersection drives the initialize fallback, which then fails
      send_error(
        client,
        Builders.build_error(-32_022, "Unsupported protocol version", probe_id, %{"supported" => ["9999-01-01"]})
      )

      request_id = get_request_id(client, "initialize")
      assert request_id

      send_error(client, Builders.build_error(-32_601, "Method not found", request_id))
      sync_client(client)

      assert Anubis.Client.get_era(client) == :detecting

      GenServer.cast(client, :connect)
      assert get_request_id(client, "server/discover")

      # the failed initialize's error stays set until a later successful detection
      assert :sys.get_state(client).initialization_error
    end
  end
end
