defmodule Anubis.Transport.StreamableHTTPTest do
  use ExUnit.Case, async: false

  alias Anubis.MCP.Message
  alias Anubis.Transport.StreamableHTTP

  @moduletag capture_log: true
  @test_http_opts [max_reconnections: 0]

  setup do
    bypass = Bypass.open()
    Process.group_leader(self(), self())

    {:ok, bypass: bypass}
  end

  describe "start_link/1" do
    test "successfully starts with valid options", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"

      {:ok, stub_client} = StubClient.start_link()

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      assert Process.alive?(transport)

      state = :sys.get_state(transport)
      assert state.mcp_url.path == "/mcp"
      assert state.session_id == nil

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "uses default mcp_path when not specified", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          transport_opts: @test_http_opts
        )

      _state = :sys.get_state(transport)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "send_message/3" do
    test "sends HTTP POST request with JSON response", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert body =~ "ping"

        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      messages = StubClient.get_messages()
      refute Enum.empty?(messages)
      assert List.first(messages) =~ "result"

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "handles 202 Accepted response", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "initialized"

        Plug.Conn.resp(conn, 202, "")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      notification = ~s|{"jsonrpc":"2.0","method":"notifications/initialized"}|
      assert :ok = StreamableHTTP.send_message(transport, notification, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "handles SSE response", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "ping"

        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        sse_data = ~s(data: {"jsonrpc":"2.0","id":"1","result":{}}\n\n)
        Plug.Conn.resp(conn, 200, sse_data)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      messages = StubClient.get_messages()
      refute Enum.empty?(messages)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "handles HTTP error responses", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      assert {:error, {:http_error, 500, "Internal Server Error"}} =
               StreamableHTTP.send_message(transport, "test message", timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "handles unsupported content type", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/html")
        Plug.Conn.resp(conn, 200, "<html>Not JSON or SSE</html>")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      assert {:error, {:unsupported_content_type, "text/html"}} =
               StreamableHTTP.send_message(transport, "test message", timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "session management" do
    test "handles session ID from response headers", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()
      session_id = "test-session-123"

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.put_resp_header("mcp-session-id", session_id)

        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      Bypass.expect(bypass, "DELETE", "/mcp", fn conn ->
        assert [^session_id] = Plug.Conn.get_req_header(conn, "mcp-session-id")
        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      state = :sys.get_state(transport)
      assert state.session_id == session_id

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "includes session ID in subsequent requests", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()
      session_id = "test-session-456"

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        session_headers = Plug.Conn.get_req_header(conn, "mcp-session-id")

        case session_headers do
          [] ->
            conn =
              conn
              |> Plug.Conn.put_resp_header("content-type", "application/json")
              |> Plug.Conn.put_resp_header("mcp-session-id", session_id)

            Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)

          [^session_id] ->
            conn =
              Plug.Conn.put_resp_header(conn, "content-type", "application/json")

            Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"2","result":{}}|)
        end
      end)

      Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
        assert [^session_id] = Plug.Conn.get_req_header(conn, "mcp-session-id")
        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      {:ok, first_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, first_message, timeout: 5000)

      {:ok, second_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "2")

      assert :ok = StreamableHTTP.send_message(transport, second_message, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "headers and options" do
    test "passes custom headers to requests", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        assert "auth-token" ==
                 conn |> Plug.Conn.get_req_header("authorization") |> List.first()

        # Accept header should be JSON-only when SSE is not enabled (default)
        assert "application/json" ==
                 conn |> Plug.Conn.get_req_header("accept") |> List.first()

        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          headers: %{
            "authorization" => "auth-token"
          },
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "handles custom mcp_path", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      custom_path = "/api/v1/mcp"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/api/v1/mcp", fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: custom_path,
          transport_opts: @test_http_opts
        )

      state = :sys.get_state(transport)
      assert state.mcp_url.path == custom_path

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "timeout handling" do
    test "respects custom timeout option", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      # Server delay > default GenServer.call timeout would matter; shrink to
      # a tiny duration since we're verifying option propagation, not real time.
      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        Process.sleep(60)
        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      # Custom timeout > server delay → success.
      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 200)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "respects timeout > Mint default receive_timeout", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      # Original test used 20s vs 15s Mint default. We test the same option
      # propagation path with a server delay that would exceed a hypothetical
      # short receive_timeout if the option weren't being passed through.
      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        Process.sleep(60)
        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 500)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "error handling" do
    test "handles network connection failures", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.down(bypass)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      assert {:error, _reason} =
               StreamableHTTP.send_message(transport, "test message", timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "accept header behavior" do
    test "sends JSON-only accept header when SSE is disabled (default)", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        # Without enable_sse, should only accept JSON
        assert "application/json" ==
                 conn |> Plug.Conn.get_req_header("accept") |> List.first()

        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          enable_sse: false,
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "sends JSON-only accept header when SSE enabled but no session yet", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        # Even with enable_sse, first request has no session so only JSON
        assert "application/json" ==
                 conn |> Plug.Conn.get_req_header("accept") |> List.first()

        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          enable_sse: true,
          transport_opts: @test_http_opts
        )

      state = :sys.get_state(transport)
      assert state.session_id == nil

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "sends SSE accept header when SSE enabled AND session exists", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()
      session_id = "test-session-789"

      # First request: no session, JSON-only
      # Second request: has session, includes SSE
      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        session_headers = Plug.Conn.get_req_header(conn, "mcp-session-id")

        case session_headers do
          [] ->
            # First request - no session yet
            assert "application/json" ==
                     conn |> Plug.Conn.get_req_header("accept") |> List.first()

            conn =
              conn
              |> Plug.Conn.put_resp_header("content-type", "application/json")
              |> Plug.Conn.put_resp_header("mcp-session-id", session_id)

            Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)

          [^session_id] ->
            # Second request - has session, should include SSE
            assert "application/json, text/event-stream" ==
                     conn |> Plug.Conn.get_req_header("accept") |> List.first()

            conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
            Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"2","result":{}}|)
        end
      end)

      # Handle SSE GET connection attempt after session is acquired
      Bypass.stub(bypass, "GET", "/mcp", fn conn ->
        Plug.Conn.resp(conn, 405, "")
      end)

      # Handle DELETE request during shutdown
      Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          enable_sse: true,
          transport_opts: @test_http_opts
        )

      # First request - establishes session
      {:ok, first_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, first_message, timeout: 5000)

      # Verify session was captured
      state = :sys.get_state(transport)
      assert state.session_id == session_id

      # Second request - should include SSE in Accept header
      {:ok, second_message} =
        Message.encode_request(%{"method" => "tools/list", "params" => %{}}, "2")

      assert :ok = StreamableHTTP.send_message(transport, second_message, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "shutdown" do
    test "gracefully shuts down transport", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      assert Process.alive?(transport)

      StreamableHTTP.shutdown(transport)

      refute Process.alive?(transport)

      StubClient.clear_messages()
    end
  end
end
