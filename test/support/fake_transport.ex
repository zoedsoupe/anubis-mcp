defmodule FakeTransport do
  @moduledoc """
  Per-test fake client transport implementing `Anubis.Transport.Behaviour`.

  With no expectations installed, every outbound message is forwarded to
  the test pid as `{:mcp_send, raw_json}` and acknowledged with `:ok`.

  `expect_send/2` queues a one-shot handler, mirroring Mox's staged
  `expect/3`: each outbound message pops the oldest queued handler. The
  handler runs in the *caller* process (usually the client), exactly like
  a Mox expectation, so assertions and sleeps behave as they did with Mox.
  Call `verify!/1` on test exit to fail on queued handlers that were never
  consumed.

  `shutdown/1` forwards `{:mcp_shutdown}` to the test pid instead of
  stopping the process, so the fake survives the client.

  The fake holds no link to the test process (`start/1`), because ExUnit
  tears down linked and supervised processes before user `on_exit/2`
  callbacks, which is where `verify!/1` runs. Stop it explicitly there.
  """

  @behaviour Anubis.Transport.Behaviour

  use GenServer

  def start(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start(__MODULE__, Map.new(opts), name: name)
  end

  @impl Anubis.Transport.Behaviour
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc """
  Queues a one-shot send handler. The function receives the raw JSON
  message, runs in the calling process, and its return value becomes the
  `send_message/3` reply.
  """
  def expect_send(transport \\ __MODULE__, fun) when is_function(fun, 1) do
    GenServer.call(transport, {:expect_send, fun})
  end

  @doc """
  Raises if any queued `expect_send/2` handler was never consumed.
  """
  def verify!(transport \\ __MODULE__) do
    case GenServer.call(transport, :pending_expectations) do
      0 -> :ok
      n -> raise "FakeTransport has #{n} unconsumed expect_send/2 handler(s)"
    end
  end

  @impl Anubis.Transport.Behaviour
  def send_message(transport \\ __MODULE__, message, _opts \\ []) do
    case GenServer.call(transport, :take_handler) do
      {:handler, fun} ->
        fun.(message)

      {:forward, pid} ->
        send(pid, {:mcp_send, message})
        :ok
    end
  end

  @impl Anubis.Transport.Behaviour
  def shutdown(transport \\ __MODULE__) do
    pid = GenServer.call(transport, :forward_to)
    send(pid, {:mcp_shutdown})
    :ok
  end

  @impl Anubis.Transport.Behaviour
  def supported_protocol_versions, do: :all

  @impl GenServer
  def init(%{} = opts) do
    {:ok, %{forward_to: Map.fetch!(opts, :forward_to), queue: []}}
  end

  @impl GenServer
  def handle_call({:expect_send, fun}, _from, state) do
    {:reply, :ok, %{state | queue: state.queue ++ [fun]}}
  end

  def handle_call(:pending_expectations, _from, state) do
    {:reply, length(state.queue), state}
  end

  def handle_call(:forward_to, _from, state) do
    {:reply, state.forward_to, state}
  end

  def handle_call(:take_handler, _from, state) do
    case state.queue do
      [fun | rest] -> {:reply, {:handler, fun}, %{state | queue: rest}}
      [] -> {:reply, {:forward, state.forward_to}, state}
    end
  end
end
