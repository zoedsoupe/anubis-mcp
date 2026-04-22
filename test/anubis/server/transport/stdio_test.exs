defmodule Anubis.Server.Transport.STDIOTest do
  use Anubis.MCP.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Anubis.Server.Transport.STDIO

  @moduletag capture_log: true, capture_io: true

  setup :server_with_stdio_transport

  describe "start_link/1" do
    test "starts successfully with valid options", %{server: server} do
      name = :"test_stdio_transport_#{:rand.uniform(1_000_000)}"
      opts = [server: server, name: name]

      capture_log(fn ->
        assert {:ok, pid} = STDIO.start_link(opts)
        assert Process.alive?(pid)
        assert Process.whereis(name) == pid
        shutdown(pid)
      end)
    end
  end

  describe "send_message/2" do
    test "sends message via cast", %{server: server} do
      name = :"test_send_message_#{:rand.uniform(1_000_000)}"

      {:ok, pid} = STDIO.start_link(server: server, name: name)

      message = "test message"

      assert capture_io(pid, fn ->
               assert :ok = STDIO.send_message(pid, message, timeout: 5000)
               Process.sleep(50)
             end) =~ "test message"

      shutdown(pid)
    end
  end

  describe "shutdown/1" do
    test "shuts down the transport gracefully", %{server: server} do
      name = :"shutdown_test_#{:rand.uniform(1_000_000)}"

      capture_log(fn ->
        {:ok, pid} = STDIO.start_link(server: server, name: name)
        ref = Process.monitor(pid)

        assert :ok = STDIO.shutdown(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

        refute Process.whereis(name)
      end)
    end
  end

  describe "basic functionality" do
    test "starts and stops cleanly", %{server: server} do
      name = :"basic_test_#{:rand.uniform(1_000_000)}"

      capture_log(fn ->
        assert {:ok, pid} = STDIO.start_link(server: server, name: name)
        assert Process.alive?(pid)
        shutdown(pid)
      end)
    end

    test "manages reading tasks correctly", %{server: server} do
      name = :"async_test_#{:rand.uniform(1_000_000)}"

      capture_log(fn ->
        {:ok, pid} = STDIO.start_link(server: server, name: name)
        assert Process.alive?(pid)
        shutdown(pid)
      end)
    end
  end

  defp shutdown(pid) do
    ref = Process.monitor(pid)
    :ok = STDIO.shutdown(pid)
    :ok = Logger.flush()
    assert_receive {:DOWN, ^ref, _, ^pid, :normal}
  end
end
