defmodule Anubis.Server.Transport.STDIOTest do
  use Anubis.MCP.Case, async: false

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

  defp shutdown(pid) do
    ref = Process.monitor(pid)
    :ok = STDIO.shutdown(pid)
    assert_receive {:DOWN, ^ref, _, ^pid, :normal}
  end
end
