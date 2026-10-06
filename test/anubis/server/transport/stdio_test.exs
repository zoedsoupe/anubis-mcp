defmodule Anubis.Server.Transport.STDIOTest do
  use Anubis.MCP.Case, async: false

  import Anubis.Test.SyncHelpers
  import ExUnit.CaptureLog

  alias Anubis.Server.Transport.STDIO

  @moduletag capture_log: true

  setup :server_with_stdio_transport

  describe "start_link/1" do
    test "starts successfully with valid options", %{server: server, io_device: io_device} do
      name = :"test_stdio_transport_#{:rand.uniform(1_000_000)}"

      assert {:ok, pid} = STDIO.start_link(server: server, name: name, io_device: io_device)
      assert Process.alive?(pid)
      assert Process.whereis(name) == pid
      shutdown(pid)
    end
  end

  describe "send_message/2" do
    test "sends message via cast", %{server: server, io_device: io_device} do
      name = :"test_send_message_#{:rand.uniform(1_000_000)}"

      {:ok, pid} = STDIO.start_link(server: server, name: name, io_device: io_device)

      assert :ok = STDIO.send_message(pid, "test message", timeout: 5000)

      assert TestIODevice.contents(io_device) =~ "test message"

      shutdown(pid)
    end
  end

  describe "shutdown/1" do
    test "shuts down the transport gracefully", %{server: server, io_device: io_device} do
      name = :"shutdown_test_#{:rand.uniform(1_000_000)}"

      {:ok, pid} = STDIO.start_link(server: server, name: name, io_device: io_device)
      ref = Process.monitor(pid)

      assert :ok = STDIO.shutdown(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

      refute Process.whereis(name)
    end
  end

  describe "basic functionality" do
    test "starts and stops cleanly", %{server: server, io_device: io_device} do
      name = :"basic_test_#{:rand.uniform(1_000_000)}"

      assert {:ok, pid} = STDIO.start_link(server: server, name: name, io_device: io_device)
      assert Process.alive?(pid)
      shutdown(pid)
    end

    test "manages reading tasks correctly", %{server: server, io_device: io_device} do
      name = :"async_test_#{:rand.uniform(1_000_000)}"

      {:ok, pid} = STDIO.start_link(server: server, name: name, io_device: io_device)
      assert Process.alive?(pid)
      shutdown(pid)
    end
  end

  describe "decode errors" do
    @tag capture_log: false
    test "unknown methods get an error with the request ID", context do
      for id <- ["probe-1", 0, 42] do
        line = JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => "unknown/probe"})
        log = capture_log(fn -> input(context, line) end)
        assert log =~ "parse_error"
        assert log =~ "method_not_found"
        response = List.last(responses(context))
        assert response["id"] == id
        assert response["error"]["code"] == -32_601
      end

      assert length(responses(context)) == 3
    end

    @tag capture_log: false
    test "invalid requests preserve valid IDs and use null otherwise", context do
      for {message, expected_id} <- [
            {%{"jsonrpc" => "2.0", "id" => "bad-1", "method" => 123}, "bad-1"},
            {%{"jsonrpc" => "2.0", "id" => true, "method" => "ping"}, nil},
            {%{"jsonrpc" => "2.0", "method" => 123}, nil},
            {%{}, nil},
            {[], nil}
          ] do
        log = capture_log(fn -> input(context, JSON.encode!(message)) end)
        assert log =~ "invalid_request"
        response = List.last(responses(context))
        assert response["jsonrpc"] == "2.0"
        assert Map.fetch!(response, "id") == expected_id
        assert response["error"]["code"] == -32_600
      end

      assert length(responses(context)) == 5
    end

    @tag capture_log: false
    test "malformed JSON receives a parse error with a null ID", context do
      log = capture_log(fn -> input(context, "{") end)
      assert log =~ "parse_error"
      assert [%{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32_700}}] = responses(context)
    end

    @tag capture_log: false
    test "unknown and invalid notifications receive no response", context do
      for message <- [
            %{"jsonrpc" => "2.0", "method" => "notifications/unknown"},
            %{"jsonrpc" => "2.0", "method" => "notifications/progress", "params" => %{}}
          ] do
        log = capture_log(fn -> input(context, JSON.encode!(message)) end)
        assert log =~ "parse_error"
      end

      assert TestIODevice.contents(context.io_device) == ""
    end

    @tag capture_log: false
    test "malformed responses do not trigger an error response", context do
      for message <- [
            %{"jsonrpc" => "2.0", "id" => 1, "error" => "invalid"},
            %{"jsonrpc" => "1.0", "id" => 1, "result" => %{}}
          ] do
        log = capture_log(fn -> input(context, JSON.encode!(message)) end)
        assert log =~ "invalid_request"
      end

      assert TestIODevice.contents(context.io_device) == ""
    end

    @tag capture_log: false
    test "a client can initialize after an unknown-method probe", context do
      probe = JSON.encode!(%{"jsonrpc" => "2.0", "id" => "probe", "method" => "unknown/probe"})
      log = capture_log(fn -> input(context, probe) end)
      assert log =~ "method_not_found"
      assert [%{"id" => "probe", "error" => %{"code" => -32_601}}] = responses(context)

      initialize = %{
        "jsonrpc" => "2.0",
        "id" => "init",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "fallback-client", "version" => "1.0.0"}
        }
      }

      input(context, JSON.encode!(initialize))
      assert [_, %{"id" => "init", "result" => %{"protocolVersion" => "2025-11-25"}}] = responses(context)
      assert Process.alive?(context.transport)
    end
  end

  defp input(context, line) do
    ref = :sys.get_state(context.transport).reading_task.ref
    :ok = TestIODevice.input(context.io_device, line <> "\n")
    await_state(context.transport, &(&1.reading_task.ref != ref))
  end

  defp responses(context) do
    context.io_device
    |> TestIODevice.contents()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp shutdown(pid) do
    ref = Process.monitor(pid)
    :ok = STDIO.shutdown(pid)
    assert_receive {:DOWN, ^ref, _, ^pid, :normal}
  end
end
