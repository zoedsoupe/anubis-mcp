defmodule Anubis.Transport.SSETest do
  use ExUnit.Case, async: false

  alias Anubis.MCP.Message
  alias Anubis.Test.SyncHelpers
  alias Anubis.Transport.SSE

  @moduletag capture_log: true
  @test_http_opts [max_reconnections: 0]

  setup do
    bypass = Bypass.open()
    Process.group_leader(self(), self())

    {:ok, bypass: bypass}
  end

  describe "start_link/1" do
    test "successfully establishes SSE connection", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"

      # Start a stub client to avoid interference with other tests
      {:ok, stub_client} = StubClient.start_link()

      # Let the SSE connection establish and send an endpoint event
      Bypass.expect(bypass, "GET", "/sse", fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, """
          event: endpoint
          data: /messages/123

          """)

        conn
      end)

      # Start the transport manually instead of using start_supervised!
      # This prevents the test framework from killing it abruptly
      {:ok, transport} =
        SSE.start_link(
          client: stub_client,
          server: %{
            base_url: server_url,
            sse_path: "/sse"
          },
          transport_opts: @test_http_opts
        )

      state = SyncHelpers.await_state(transport, & &1.message_url)
      assert String.ends_with?(to_string(state.message_url), "/messages/123")

      StubClient.clear_messages()
      ref = Process.monitor(transport)
      SSE.shutdown(transport)
      assert_receive {:DOWN, ^ref, :process, _, _}, 500
    end
  end

  describe "send_message/2" do
    test "sends message to endpoint after receiving endpoint event", %{
      bypass: bypass
    } do
      server_url = "http://localhost:#{bypass.port}"

      # Start a stub client
      {:ok, stub_client} = StubClient.start_link()

      # Set up SSE connection
      Bypass.expect(bypass, "GET", "/sse", fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, """
          event: endpoint
          data: /messages/123

          """)

        conn
      end)

      # Set up POST endpoint that will receive messages
      Bypass.expect(bypass, "POST", "/messages/123", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        # Verify we got a message
        assert body =~ "ping"

        # Return a proper response
        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

        # For a ping request, just send back a simple response
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":"pong"}|)
      end)

      # Start the transport with our stub client
      {:ok, transport} =
        SSE.start_link(
          client: stub_client,
          server: %{
            base_url: server_url,
            sse_path: "/sse"
          },
          transport_opts: @test_http_opts
        )

      transport_state = SyncHelpers.await_state(transport, & &1.message_url)

      assert String.ends_with?(
               to_string(transport_state.message_url),
               "/messages/123"
             )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = SSE.send_message(transport, ping_message, timeout: 5000)

      StubClient.clear_messages()
      SSE.shutdown(transport)
    end

    test "fails to send message when no endpoint is available", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"

      # Start a stub client for this test
      {:ok, stub_client} = StubClient.start_link()

      # Set up the SSE connection but don't send an endpoint event
      Bypass.stub(bypass, "GET", "/sse", fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        Plug.Conn.send_chunked(conn, 200)
      end)

      # Start the SSE transport
      {:ok, transport} =
        SSE.start_link(
          client: stub_client,
          server: %{
            base_url: server_url,
            sse_path: "/sse"
          },
          transport_opts: @test_http_opts
        )

      assert {:error, :not_connected} = SSE.send_message(transport, "test message", timeout: 5000)

      # Clean up
      SSE.shutdown(transport)
      StubClient.clear_messages()
    end

    test "handles HTTP error responses", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"

      # Start a stub client for this test to avoid client termination affecting transport
      {:ok, stub_client} = StubClient.start_link()

      # Set up the SSE connection
      Bypass.expect(bypass, "GET", "/sse", fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        # Send an endpoint event
        {:ok, conn} =
          Plug.Conn.chunk(conn, """
          event: endpoint
          data: /messages/123

          """)

        conn
      end)

      # Set up the POST endpoint to return an error
      Bypass.expect(bypass, "POST", "/messages/123", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      # Start the SSE transport
      {:ok, transport} =
        SSE.start_link(
          client: stub_client,
          server: %{
            base_url: server_url,
            sse_path: "/sse"
          },
          transport_opts: @test_http_opts
        )

      _ = SyncHelpers.await_state(transport, & &1.message_url)

      assert {:error, {:http_error, 500, "Internal Server Error"}} =
               SSE.send_message(transport, "test message", timeout: 5000)

      # Clean up
      SSE.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "handling SSE events" do
    test "processes message events correctly", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"

      # Create a test message
      test_message = "test message data"

      # Start the StubClient from test_helpers.exs
      {:ok, stub_client} = StubClient.start_link()
      StubClient.subscribe()

      # Set up the SSE connection
      Bypass.expect(bypass, "GET", "/sse", fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        # Send an endpoint event
        {:ok, conn} =
          Plug.Conn.chunk(conn, """
          event: endpoint
          data: /messages/123

          """)

        # Send a message event after a slight delay to ensure
        # the endpoint message is processed first
        Process.sleep(50)

        {:ok, conn} =
          Plug.Conn.chunk(conn, """
          event: message
          data: #{test_message}

          """)

        conn
      end)

      # Start the SSE transport with the stub client
      {:ok, transport} =
        SSE.start_link(
          client: stub_client,
          server: %{
            base_url: server_url,
            sse_path: "/sse"
          },
          transport_opts: @test_http_opts
        )

      assert_receive {:stub_client_response, ^test_message}, 500

      transport_state = :sys.get_state(transport)
      assert transport_state.message_url

      # Clean up
      StubClient.clear_messages()
      SSE.shutdown(transport)
    end

    test "handles server disconnection", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"

      # Start a stub client
      {:ok, stub_client} = StubClient.start_link()

      # Set up the SSE connection - bypass is needed but we don't assert
      # any specific behavior since we're testing disconnection
      Bypass.stub(bypass, "GET", "/sse", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      # Start the SSE transport with 0 reconnection attempts
      {:ok, transport} =
        SSE.start_link(
          client: stub_client,
          server: %{
            base_url: server_url,
            sse_path: "/sse"
          },
          transport_opts: [max_reconnections: 0]
        )

      ref = Process.monitor(transport)
      SSE.shutdown(transport)
      assert_receive {:DOWN, ^ref, :process, _, _}, 500

      # Clean up
      StubClient.clear_messages()
    end
  end

  describe "handling headers and options" do
    test "passes custom headers to requests", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "GET", "/sse", fn conn ->
        assert "auth-token" ==
                 conn |> Plug.Conn.get_req_header("authorization") |> List.first()

        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, "event: endpoint\ndata: /messages/123\n\n")

        conn
      end)

      Bypass.expect(bypass, "POST", "/messages/123", fn conn ->
        assert "application/json" ==
                 conn |> Plug.Conn.get_req_header("accept") |> List.first()

        assert "auth-token" ==
                 conn |> Plug.Conn.get_req_header("authorization") |> List.first()

        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, transport} =
        SSE.start_link(
          client: stub_client,
          server: %{
            base_url: server_url,
            sse_path: "/sse"
          },
          headers: %{
            "accept" => "application/json",
            "authorization" => "auth-token"
          },
          transport_opts: @test_http_opts
        )

      _ = SyncHelpers.await_state(transport, & &1.message_url)
      assert :ok = SSE.send_message(transport, "test message", timeout: 5000)

      SSE.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "handling endpoint URLs" do
    test "properly handles relative endpoint URLs", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}/mcp"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "GET", "/mcp/sse", fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, "event: endpoint\ndata: /messages/123\n\n")

        conn
      end)

      Bypass.expect(bypass, "POST", "/mcp/messages/123", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, transport} =
        SSE.start_link(
          client: stub_client,
          server: %{
            base_url: server_url,
            sse_path: "/sse"
          },
          transport_opts: @test_http_opts
        )

      transport_state = SyncHelpers.await_state(transport, & &1.message_url)
      assert transport_state.message_url == "#{server_url}/messages/123"
      assert :ok = SSE.send_message(transport, "test message", timeout: 5000)

      SSE.shutdown(transport)
      StubClient.clear_messages()
    end

    test "properly handles absolute endpoint URLs", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}/mcp"
      absolute_endpoint = "http://api.example.com/messages/session-123"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "GET", "/mcp/sse", fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, "event: endpoint\ndata: #{absolute_endpoint}\n\n")

        conn
      end)

      {:ok, transport} =
        SSE.start_link(
          client: stub_client,
          server: %{
            base_url: server_url,
            sse_path: "/sse"
          },
          transport_opts: @test_http_opts
        )

      transport_state = SyncHelpers.await_state(transport, & &1.message_url)
      assert transport_state.message_url == absolute_endpoint

      SSE.shutdown(transport)
      StubClient.clear_messages()
    end

    test "handles path duplication from MCP servers", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}/mcp"
      duplicate_path = "/mcp/messages/123"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "GET", "/mcp/sse", fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, "event: endpoint\ndata: #{duplicate_path}\n\n")

        conn
      end)

      Bypass.expect(bypass, "POST", "/mcp/messages/123", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, transport} =
        SSE.start_link(
          client: stub_client,
          server: %{
            base_url: server_url,
            sse_path: "/sse"
          },
          transport_opts: @test_http_opts
        )

      transport_state = SyncHelpers.await_state(transport, & &1.message_url)
      assert transport_state.message_url == "#{server_url}/messages/123"
      refute String.contains?(transport_state.message_url, "/mcp/mcp/")
      assert :ok = SSE.send_message(transport, "test message", timeout: 5000)

      SSE.shutdown(transport)
      StubClient.clear_messages()
    end
  end
end
