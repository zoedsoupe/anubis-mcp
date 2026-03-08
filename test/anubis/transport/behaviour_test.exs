defmodule Anubis.Transport.BehaviourTest do
  @moduledoc """
  Tests for the functional `Anubis.Transport` behaviour implementations.

  Verifies transport_init/1, parse/2, encode/2, and extract_metadata/2
  callbacks across all client transport modules.
  """

  use ExUnit.Case, async: true

  alias Anubis.Transport.SSE, as: ClientSSE
  alias Anubis.Transport.STDIO, as: ClientSTDIO
  alias Anubis.Transport.StreamableHTTP, as: ClientHTTP

  @sample_request %{
    "jsonrpc" => "2.0",
    "method" => "ping",
    "id" => 1
  }

  @sample_response %{
    "jsonrpc" => "2.0",
    "result" => %{},
    "id" => 1
  }

  @sample_notification %{
    "jsonrpc" => "2.0",
    "method" => "notifications/initialized"
  }

  describe "Client STDIO transport" do
    test "transport_init/1 returns ok with buffer state" do
      assert {:ok, %{buffer: ""}} = ClientSTDIO.transport_init()
    end

    test "parse/2 decodes newline-delimited JSON" do
      {:ok, state} = ClientSTDIO.transport_init()
      json = JSON.encode!(@sample_request) <> "\n"

      assert {:ok, [@sample_request], %{buffer: ""}} = ClientSTDIO.parse(json, state)
    end

    test "parse/2 handles multiple messages" do
      {:ok, state} = ClientSTDIO.transport_init()

      json =
        JSON.encode!(@sample_request) <>
          "\n" <> JSON.encode!(@sample_response) <> "\n"

      assert {:ok, [@sample_request, @sample_response], %{buffer: ""}} =
               ClientSTDIO.parse(json, state)
    end

    test "parse/2 buffers incomplete messages" do
      {:ok, state} = ClientSTDIO.transport_init()
      partial = ~s({"jsonrpc": "2.0", "method")

      assert {:ok, [], %{buffer: ^partial}} = ClientSTDIO.parse(partial, state)
    end

    test "parse/2 handles buffered data across calls" do
      {:ok, state} = ClientSTDIO.transport_init()
      part1 = ~s({"jsonrpc": "2.0",)
      part2 = ~s( "method": "ping", "id": 1}\n)

      assert {:ok, [], state} = ClientSTDIO.parse(part1, state)
      assert {:ok, [msg], %{buffer: ""}} = ClientSTDIO.parse(part2, state)
      assert msg["method"] == "ping"
    end

    test "parse/2 returns error on invalid JSON" do
      {:ok, state} = ClientSTDIO.transport_init()
      assert {:error, :invalid_json} = ClientSTDIO.parse("not json\n", state)
    end

    test "parse/2 returns error on non-object JSON" do
      {:ok, state} = ClientSTDIO.transport_init()
      assert {:error, :invalid_message} = ClientSTDIO.parse("[1,2,3]\n", state)
    end

    test "encode/2 produces JSON with newline" do
      {:ok, state} = ClientSTDIO.transport_init()

      assert {:ok, encoded, ^state} = ClientSTDIO.encode(@sample_request, state)
      assert String.ends_with?(encoded, "\n")
      assert {:ok, decoded} = JSON.decode(String.trim(encoded))
      assert decoded == @sample_request
    end

    test "parse/encode round-trip" do
      {:ok, state} = ClientSTDIO.transport_init()

      {:ok, encoded, state} = ClientSTDIO.encode(@sample_request, state)
      {:ok, [decoded], _state} = ClientSTDIO.parse(encoded, state)

      assert decoded == @sample_request
    end

    test "extract_metadata/2 returns stdio transport type" do
      {:ok, state} = ClientSTDIO.transport_init()
      assert %{transport: :stdio} = ClientSTDIO.extract_metadata(nil, state)
    end
  end

  describe "Client StreamableHTTP transport" do
    test "transport_init/1 returns ok with default state" do
      assert {:ok, %{session_id: nil, last_event_id: nil}} = ClientHTTP.transport_init()
    end

    test "transport_init/1 accepts options" do
      assert {:ok, %{session_id: "sess_123"}} =
               ClientHTTP.transport_init(session_id: "sess_123")
    end

    test "parse/2 decodes JSON string" do
      {:ok, state} = ClientHTTP.transport_init()
      json = JSON.encode!(@sample_request)

      assert {:ok, [@sample_request], ^state} = ClientHTTP.parse(json, state)
    end

    test "parse/2 accepts already-decoded maps" do
      {:ok, state} = ClientHTTP.transport_init()
      assert {:ok, [@sample_request], ^state} = ClientHTTP.parse(@sample_request, state)
    end

    test "parse/2 handles JSON arrays (batching)" do
      {:ok, state} = ClientHTTP.transport_init()
      batch = JSON.encode!([@sample_request, @sample_response])

      assert {:ok, [@sample_request, @sample_response], ^state} =
               ClientHTTP.parse(batch, state)
    end

    test "parse/2 returns error on invalid JSON" do
      {:ok, state} = ClientHTTP.transport_init()
      assert {:error, :invalid_json} = ClientHTTP.parse("not json", state)
    end

    test "encode/2 produces JSON without newline" do
      {:ok, state} = ClientHTTP.transport_init()

      assert {:ok, encoded, ^state} = ClientHTTP.encode(@sample_request, state)
      refute String.ends_with?(encoded, "\n")
      assert {:ok, decoded} = JSON.decode(encoded)
      assert decoded == @sample_request
    end

    test "parse/encode round-trip" do
      {:ok, state} = ClientHTTP.transport_init()

      {:ok, encoded, state} = ClientHTTP.encode(@sample_request, state)
      {:ok, [decoded], _state} = ClientHTTP.parse(encoded, state)

      assert decoded == @sample_request
    end

    test "extract_metadata/2 extracts session_id from headers" do
      {:ok, state} = ClientHTTP.transport_init()

      headers = [{"mcp-session-id", "sess_abc"}, {"content-type", "application/json"}]
      metadata = ClientHTTP.extract_metadata(headers, state)

      assert metadata.transport == :streamable_http
      assert metadata.session_id == "sess_abc"
    end

    test "extract_metadata/2 falls back to state session_id" do
      {:ok, state} = ClientHTTP.transport_init(session_id: "sess_fallback")

      metadata = ClientHTTP.extract_metadata([], state)
      assert metadata.session_id == "sess_fallback"
    end

    test "extract_metadata/2 handles non-header input" do
      {:ok, state} = ClientHTTP.transport_init(session_id: "s1")

      metadata = ClientHTTP.extract_metadata(:something, state)
      assert metadata.transport == :streamable_http
      assert metadata.session_id == "s1"
    end
  end

  describe "Client SSE transport" do
    test "transport_init/1 returns ok with default state" do
      assert {:ok, %{message_url: nil, last_event_id: nil}} = ClientSSE.transport_init()
    end

    test "parse/2 decodes JSON string" do
      {:ok, state} = ClientSSE.transport_init()
      json = JSON.encode!(@sample_request)

      assert {:ok, [@sample_request], ^state} = ClientSSE.parse(json, state)
    end

    test "parse/2 accepts already-decoded maps" do
      {:ok, state} = ClientSSE.transport_init()
      assert {:ok, [@sample_request], ^state} = ClientSSE.parse(@sample_request, state)
    end

    test "parse/2 returns error on non-object JSON" do
      {:ok, state} = ClientSSE.transport_init()
      assert {:error, :invalid_message} = ClientSSE.parse("[1,2]", state)
    end

    test "encode/2 produces JSON with newline" do
      {:ok, state} = ClientSSE.transport_init()

      assert {:ok, encoded, ^state} = ClientSSE.encode(@sample_request, state)
      assert String.ends_with?(encoded, "\n")
    end

    test "extract_metadata/2 with SSE Event struct" do
      {:ok, state} = ClientSSE.transport_init(message_url: "http://localhost/messages")
      event = %Anubis.SSE.Event{event: "message", data: "data", id: "evt_1"}

      metadata = ClientSSE.extract_metadata(event, state)
      assert metadata.transport == :sse
      assert metadata.event_type == "message"
      assert metadata.event_id == "evt_1"
      assert metadata.message_url == "http://localhost/messages"
    end

    test "extract_metadata/2 without Event struct" do
      {:ok, state} = ClientSSE.transport_init()
      metadata = ClientSSE.extract_metadata(nil, state)
      assert metadata.transport == :sse
    end
  end

  describe "cross-transport consistency" do
    @transports [
      {ClientSTDIO, :client_stdio},
      {ClientHTTP, :client_http},
      {ClientSSE, :client_sse}
    ]

    for {mod, label} <- @transports do
      test "#{label} implements transport_init/1" do
        assert {:ok, _state} = unquote(mod).transport_init()
      end

      test "#{label} can parse a valid JSON-RPC request" do
        {:ok, state} = unquote(mod).transport_init()

        json =
          if unquote(mod) in [ClientSTDIO] do
            JSON.encode!(@sample_request) <> "\n"
          else
            JSON.encode!(@sample_request)
          end

        assert {:ok, [msg], _state} = unquote(mod).parse(json, state)
        assert msg["jsonrpc"] == "2.0"
        assert msg["method"] == "ping"
      end

      test "#{label} rejects invalid JSON" do
        {:ok, state} = unquote(mod).transport_init()

        # STDIO transports need newline to process
        input =
          if unquote(mod) in [ClientSTDIO] do
            "not valid json\n"
          else
            "not valid json"
          end

        assert {:error, _reason} = unquote(mod).parse(input, state)
      end
    end
  end
end
