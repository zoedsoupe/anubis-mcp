defmodule TestIODevice do
  @moduledoc """
  Minimal Erlang IO-protocol server for exercising `Anubis.Server.Transport.STDIO` in tests.

  Read requests block until a line is supplied via `input/2`, mirroring a live stdin.
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

  @spec input(GenServer.server(), binary()) :: :ok
  def input(device, line), do: GenServer.call(device, {:input, line})

  @impl GenServer
  def init(:ok) do
    {:ok, %{output: [], input: :queue.new(), readers: :queue.new()}}
  end

  @impl GenServer
  def handle_info({:io_request, from, reply_as, request}, state) do
    handle_io_request(request, from, reply_as, state)
  end

  @impl GenServer
  def handle_call(:contents, _from, state) do
    {:reply, state.output |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  def handle_call({:input, line}, _from, state) do
    case :queue.out(state.readers) do
      {{:value, {reader, reply_as}}, readers} ->
        send(reader, {:io_reply, reply_as, line})
        {:reply, :ok, %{state | readers: readers}}

      {:empty, _} ->
        {:reply, :ok, %{state | input: :queue.in(line, state.input)}}
    end
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

  defp handle_io_request({:get_line, _encoding, _prompt}, from, reply_as, state), do: read_line(from, reply_as, state)

  defp handle_io_request({:get_line, _prompt}, from, reply_as, state), do: read_line(from, reply_as, state)
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

  defp read_line(from, reply_as, state) do
    case :queue.out(state.input) do
      {{:value, line}, input} ->
        send(from, {:io_reply, reply_as, line})
        {:noreply, %{state | input: input}}

      {:empty, _} ->
        {:noreply, %{state | readers: :queue.in({from, reply_as}, state.readers)}}
    end
  end
end
