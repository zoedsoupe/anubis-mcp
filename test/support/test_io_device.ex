defmodule TestIODevice do
  @moduledoc """
  Minimal Erlang IO-protocol server for exercising `Anubis.Server.Transport.STDIO` in tests.

  Read requests are intentionally never replied to, so a reader task blocks forever
  instead of seeing `:eof` — this mirrors a live stdin while keeping tests deterministic.
  Write requests are buffered and can be retrieved via `contents/1`.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @spec contents(GenServer.server()) :: binary()
  def contents(device) do
    GenServer.call(device, :contents)
  end

  @impl GenServer
  def init(:ok) do
    {:ok, %{output: []}}
  end

  @impl GenServer
  def handle_info({:io_request, from, reply_as, request}, state) do
    handle_io_request(request, from, reply_as, state)
  end

  @impl GenServer
  def handle_call(:contents, _from, state) do
    {:reply, state.output |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  defp handle_io_request({:put_chars, _encoding, chars}, from, reply_as, state) do
    send(from, {:io_reply, reply_as, :ok})
    {:noreply, %{state | output: [chars | state.output]}}
  end

  defp handle_io_request({:put_chars, chars}, from, reply_as, state) do
    send(from, {:io_reply, reply_as, :ok})
    {:noreply, %{state | output: [chars | state.output]}}
  end

  defp handle_io_request({:put_chars, _encoding, mod, fun, args}, from, reply_as, state) do
    chars = apply(mod, fun, args)
    send(from, {:io_reply, reply_as, :ok})
    {:noreply, %{state | output: [chars | state.output]}}
  end

  defp handle_io_request({:get_line, _encoding, _prompt}, _from, _reply_as, state), do: {:noreply, state}
  defp handle_io_request({:get_line, _prompt}, _from, _reply_as, state), do: {:noreply, state}
  defp handle_io_request({:get_chars, _encoding, _prompt, _n}, _from, _reply_as, state), do: {:noreply, state}
  defp handle_io_request({:get_chars, _prompt, _n}, _from, _reply_as, state), do: {:noreply, state}

  defp handle_io_request({:get_until, _encoding, _prompt, _mod, _fun, _args}, _from, _reply_as, state),
    do: {:noreply, state}

  defp handle_io_request({:get_until, _prompt, _mod, _fun, _args}, _from, _reply_as, state), do: {:noreply, state}

  defp handle_io_request({:setopts, _opts}, from, reply_as, state) do
    send(from, {:io_reply, reply_as, :ok})
    {:noreply, state}
  end

  defp handle_io_request(:getopts, from, reply_as, state) do
    send(from, {:io_reply, reply_as, [binary: true, encoding: :utf8]})
    {:noreply, state}
  end

  defp handle_io_request(_other, from, reply_as, state) do
    send(from, {:io_reply, reply_as, {:error, :request}})
    {:noreply, state}
  end
end
