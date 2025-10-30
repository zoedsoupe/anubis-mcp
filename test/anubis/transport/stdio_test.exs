defmodule Anubis.Transport.STDIOTest do
  use ExUnit.Case, async: false

  alias Anubis.Transport.STDIO

  @moduletag capture_log: true

  setup do
    start_supervised!(StubClient)

    command = if :os.type() == {:win32, :nt}, do: "cmd", else: "echo"

    %{command: command}
  end

  describe "start_link/1" do
    test "successfully starts transport", %{command: command} do
      opts = [
        client: StubClient,
        command: command,
        args: ["hello"],
        name: :test_transport
      ]

      assert {:ok, pid} = STDIO.start_link(opts)
      assert Process.whereis(:test_transport)

      safe_stop(pid)
    end

    test "fails when command not found" do
      opts = [
        client: StubClient,
        command: "abc",
        name: :should_fail
      ]

      assert {:ok, pid} = STDIO.start_link(opts)
      Process.flag(:trap_exit, true)
      assert_receive {:EXIT, ^pid, {:error, _}}
    end
  end

  describe "send_message/2" do
    setup %{command: command} do
      {:ok, pid} =
        STDIO.start_link(
          client: StubClient,
          command: command,
          args: ["test"],
          name: :test_send_transport
        )

      on_exit(fn -> safe_stop(pid) end)

      %{transport_pid: pid}
    end

    test "sends message successfully", %{transport_pid: pid} do
      assert :ok = STDIO.send_message(pid, "test message", timeout: 5000)
    end

    test "respects custom timeout option" do
      # Create a mock transport GenServer that will block for 6 seconds on handle_call
      defmodule SlowTransport do
        @moduledoc false
        use GenServer

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts, name: opts[:name])
        end

        def init(opts), do: {:ok, opts}

        def handle_call({:send, _message}, _from, state) do
          # Simulate a slow operation that takes 6 seconds
          Process.sleep(6000)
          {:reply, :ok, state}
        end
      end

      {:ok, transport} = SlowTransport.start_link(name: :slow_transport_test)

      on_exit(fn ->
        if Process.alive?(transport) do
          GenServer.stop(transport, :normal, 100)
        end
      end)

      # Test: With a 10s timeout, the call should succeed (10s > 6s)
      # Before fix: if opts[:timeout] returned nil, GenServer.call would use 5s default and timeout
      # After fix: Keyword.get(opts, :timeout, 5000) properly extracts the timeout value
      result = STDIO.send_message(transport, "test1", timeout: 10_000)
      assert result == :ok, "Should succeed with 10s timeout"
    end
  end

  describe "client message handling" do
    setup do
      command = if :os.type() == {:win32, :nt}, do: "cmd", else: "cat"

      {:ok, pid} =
        STDIO.start_link(
          client: StubClient,
          command: command,
          name: :test_echo_transport
        )

      on_exit(fn -> safe_stop(pid) end)

      %{transport_pid: pid}
    end

    test "forwards data to client", %{transport_pid: pid} do
      :ok = StubClient.clear_messages()

      STDIO.send_message(pid, "echo test\n", timeout: 5000)

      Process.sleep(100)

      messages = StubClient.get_messages()
      assert length(messages) > 0
    end
  end

  describe "port behavior" do
    test "handles port restart on close" do
      command = if :os.type() == {:win32, :nt}, do: "cmd", else: "echo"

      transport_name = :restart_test_transport

      {:ok, pid} =
        STDIO.start_link(
          client: StubClient,
          command: command,
          name: transport_name
        )

      original_pid = Process.whereis(transport_name)
      assert original_pid

      ref = Process.monitor(original_pid)

      safe_stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^original_pid, _}, 1000
    end
  end

  describe "environment variables" do
    test "uses environment variables" do
      command = if :os.type() == {:win32, :nt}, do: "cmd", else: "echo"

      :ok = StubClient.clear_messages()

      {:ok, pid} =
        STDIO.start_link(
          client: StubClient,
          command: command,
          args: ["TEST_CUSTOM_VAR=test_value"],
          env: %{"TEST_CUSTOM_VAR" => "test_value"},
          name: :env_test_transport
        )

      Process.sleep(100)

      messages = StubClient.get_messages()
      assert length(messages) > 0

      safe_stop(pid)
    end
  end

  defp safe_stop(pid) do
    if is_pid(pid) && Process.alive?(pid) do
      try do
        STDIO.shutdown(pid)
        Process.sleep(50)
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 100)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
