defmodule Anubis.Server.Transport.STDIO do
  @moduledoc """
  STDIO transport implementation for MCP servers.

  This module handles communication with MCP clients via standard input/output streams,
  processing incoming JSON-RPC messages and forwarding responses directly to the
  Session process.
  """

  @behaviour Anubis.Transport.Behaviour

  use GenServer
  use Anubis.Logging

  import Peri

  alias Anubis.MCP.Message
  alias Anubis.Server.Registry
  alias Anubis.Telemetry
  alias Anubis.Transport.Behaviour, as: Transport

  require Message

  @type t :: GenServer.server()

  @typedoc """
  STDIO transport options

  - `:server` - The server module (required)
  - `:name` - Optional name for registering the GenServer
  """
  @type option ::
          {:server, GenServer.server()}
          | {:name, GenServer.name()}
          | GenServer.option()

  defschema(:parse_options, [
    {:server, {:required, {:oneof, [{:custom, &Anubis.genserver_name/1}, :pid, {:tuple, [:atom, :any]}]}}},
    {:name, {:custom, &Anubis.genserver_name/1}},
    {:request_timeout, {:integer, {:default, to_timeout(second: 30)}}}
  ])

  @impl Transport
  @spec start_link(Enumerable.t(option())) :: GenServer.on_start()
  def start_link(opts) do
    opts = parse_options!(opts)
    server_name = Keyword.get(opts, :name)

    if server_name do
      GenServer.start_link(__MODULE__, Map.new(opts), name: server_name)
    else
      GenServer.start_link(__MODULE__, Map.new(opts))
    end
  end

  @impl Transport
  def send_message(transport, message, opts) when is_binary(message) do
    GenServer.call(transport, {:send, message}, opts[:timeout])
  end

  @impl Transport
  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(transport) do
    GenServer.cast(transport, :shutdown)
  end

  @impl Transport
  def supported_protocol_versions, do: :all

  @impl GenServer
  def init(opts) do
    :ok = :io.setopts(encoding: :utf8)
    Process.flag(:trap_exit, true)

    state = %{
      server: opts.server,
      reading_task: nil,
      request_timeout: opts.request_timeout
    }

    :logger.update_handler_config(:default, :config, %{type: :standard_error})
    Logger.metadata(mcp_transport: :stdio, mcp_server: state.server)
    Logging.transport_event("starting", %{transport: :stdio, server: state.server})

    Telemetry.execute(
      Telemetry.event_transport_init(),
      %{system_time: System.system_time()},
      %{transport: :stdio, server: state.server}
    )

    {:ok, state, {:continue, :start_reading}}
  end

  @impl GenServer
  def handle_continue(:start_reading, state) do
    task = Task.async(fn -> read_from_stdin() end)
    {:noreply, %{state | reading_task: task}}
  end

  @impl GenServer
  def handle_info({ref, result}, %{reading_task: %Task{ref: ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, data} ->
        handle_incoming_data(data, state)

        task = Task.async(fn -> read_from_stdin() end)
        {:noreply, %{state | reading_task: task}}

      {:error, :eof} ->
        Logging.transport_event("eof", "Client disconnected", level: :info)
        {:stop, :normal, %{state | reading_task: nil}}

      {:error, reason} ->
        Logging.transport_event("read_error", %{reason: reason}, level: :error)
        {:stop, {:error, reason}, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:send, message}, _from, state) do
    Logging.transport_event(
      "outgoing",
      %{transport: :stdio, message_size: byte_size(message)},
      level: :debug
    )

    Telemetry.execute(
      Telemetry.event_transport_send(),
      %{system_time: System.system_time()},
      %{transport: :stdio, message_size: byte_size(message)}
    )

    IO.write(message)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast(:shutdown, %{reading_task: task} = state) do
    if task, do: Task.shutdown(task, :brutal_kill)

    Logging.transport_event("shutdown", "Transport shutting down", level: :info)

    Telemetry.execute(
      Telemetry.event_transport_disconnect(),
      %{system_time: System.system_time()},
      %{transport: :stdio, reason: :shutdown}
    )

    {:stop, :normal, state}
  end

  @impl GenServer
  def terminate(reason, _state) do
    Logging.transport_event("terminating", %{reason: reason}, level: :info)

    Telemetry.execute(
      Telemetry.event_transport_terminate(),
      %{system_time: System.system_time()},
      %{transport: :stdio, reason: reason}
    )

    :ok
  end

  # Private helper functions

  defp read_from_stdin do
    case IO.read(:stdio, :line) do
      :eof ->
        Logging.transport_event("eof", "End of input stream", level: :info)

        Telemetry.execute(
          Telemetry.event_transport_disconnect(),
          %{system_time: System.system_time()},
          %{transport: :stdio, reason: :eof}
        )

        {:error, :eof}

      {:error, reason} ->
        Logging.transport_event("read_error", %{reason: reason}, level: :error)

        Telemetry.execute(
          Telemetry.event_transport_error(),
          %{system_time: System.system_time()},
          %{transport: :stdio, reason: reason}
        )

        {:error, reason}

      data when is_binary(data) ->
        {:ok, data}
    end
  end

  defp handle_incoming_data(data, state) do
    Logging.transport_event(
      "incoming",
      %{transport: :stdio, message_size: byte_size(data)},
      level: :debug
    )

    Telemetry.execute(
      Telemetry.event_transport_receive(),
      %{system_time: System.system_time()},
      %{transport: :stdio, message_size: byte_size(data)}
    )

    case Message.decode(data) do
      {:ok, messages} ->
        Enum.each(messages, fn message ->
          process_message(message, state)
        end)

      {:error, reason} ->
        Logging.transport_event("parse_error", %{reason: reason}, level: :error)
    end
  end

  defp process_message(message, %{server: server_module} = state) do
    session_pid = Registry.stdio_session_name(server_module)

    context = %{
      type: :stdio,
      env: System.get_env(),
      pid: System.pid()
    }

    case get_session_pid(session_pid) do
      {:ok, pid} ->
        dispatch_to_session(message, pid, context, state)

      :error ->
        Logging.transport_event("no_session", %{server: server_module}, level: :error)
    end
  end

  defp get_session_pid(session_name) do
    if Process.whereis(session_name), do: {:ok, session_name}, else: :error
  end

  defp dispatch_to_session(message, session_pid, context, state) do
    if Message.is_notification(message) do
      GenServer.cast(session_pid, {:mcp_notification, message, context})
    else
      forward_request_to_session(session_pid, message, context, state.request_timeout)
    end
  end

  defp forward_request_to_session(session_pid, message, context, timeout) do
    case GenServer.call(session_pid, {:mcp_request, message, context}, timeout) do
      {:ok, response} when is_binary(response) ->
        IO.write(response <> "\n")

      {:ok, nil} ->
        :ok

      {:error, reason} ->
        Logging.transport_event("session_error", %{reason: reason}, level: :error)
    end
  catch
    :exit, reason ->
      Logging.transport_event("session_call_failed", %{reason: reason}, level: :error)
  end
end
