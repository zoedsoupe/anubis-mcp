defmodule StubClient do
  @moduledoc false
  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{messages: [], subscriber: nil}, name: __MODULE__)
  end

  def init(state) do
    {:ok, state}
  end

  def get_messages do
    GenServer.call(__MODULE__, :get_messages)
  end

  def clear_messages do
    GenServer.call(__MODULE__, :clear_messages)
  end

  @doc """
  Subscribes the given pid to `{:stub_client_response, data}` messages emitted
  whenever the stub receives a response. Auto-clears on `clear_messages/0`.
  """
  def subscribe(pid \\ self()) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  def handle_call(:get_messages, _from, %{messages: messages} = state) do
    {:reply, Enum.reverse(messages), state}
  end

  def handle_call(:clear_messages, _from, state) do
    {:reply, :ok, %{state | messages: [], subscriber: nil}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscriber: pid}}
  end

  def handle_cast(msg, state), do: handle_info(msg, state)

  def handle_info(:initialize, state), do: {:noreply, state}

  def handle_info({:response, data}, %{messages: messages, subscriber: sub} = state) do
    if sub, do: send(sub, {:stub_client_response, data})
    {:noreply, %{state | messages: [data | messages]}}
  end
end
