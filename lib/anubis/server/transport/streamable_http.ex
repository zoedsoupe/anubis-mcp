defmodule Anubis.Server.Transport.StreamableHTTP do
  @moduledoc """
  StreamableHTTP transport implementation for MCP servers.

  This module manages SSE (Server-Sent Events) connections for server-to-client
  communication. In the refactored architecture, request handling is done directly
  by Session processes - this module only manages SSE handlers and notifications.

  ## Features

  - SSE handler registration for server-to-client push
  - Automatic handler cleanup on disconnect
  - Keepalive messages to maintain connections
  - Notification broadcasting to connected clients

  ## Usage

  StreamableHTTP is typically started through the server supervisor:

      Anubis.Server.start_link(MyServer, [],
        transport: :streamable_http,
        streamable_http: [port: 4000]
      )

  For integration with existing Phoenix/Plug applications:

      # In your router
      forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug,
        server: MyApp.MCPServer
  """

  @behaviour Anubis.Transport
  @behaviour Anubis.Transport.Behaviour

  use GenServer
  use Anubis.Logging

  import Peri

  alias Anubis.Telemetry
  alias Anubis.Transport.Behaviour, as: Transport

  @type t :: GenServer.server()

  @type http_state :: %{
          session_id: String.t() | nil,
          session_header: String.t()
        }

  @impl Anubis.Transport
  @spec transport_init(keyword()) :: {:ok, http_state()} | {:error, term()}
  def transport_init(opts \\ []) do
    {:ok,
     %{
       session_id: Keyword.get(opts, :session_id),
       session_header: Keyword.get(opts, :session_header, "mcp-session-id")
     }}
  end

  @impl Anubis.Transport
  @spec parse(binary() | map(), http_state()) ::
          {:ok, [map()], http_state()} | {:error, term()}
  def parse(raw, state) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, %{} = message} ->
        {:ok, [message], state}

      {:ok, messages} when is_list(messages) ->
        if Enum.all?(messages, &is_map/1) do
          {:ok, messages, state}
        else
          {:error, :invalid_message}
        end

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  def parse(raw, state) when is_map(raw) do
    {:ok, [raw], state}
  end

  @impl Anubis.Transport
  @spec encode(map(), http_state()) :: {:ok, binary(), http_state()} | {:error, term()}
  def encode(message, state) when is_map(message) do
    {:ok, JSON.encode!(message), state}
  rescue
    e in [Protocol.UndefinedError, Jason.EncodeError] ->
      {:error, {:encode_error, Exception.message(e)}}
  end

  @impl Anubis.Transport
  @spec extract_metadata(term(), http_state()) :: map()
  def extract_metadata(%Plug.Conn{} = conn, state) do
    session_id =
      conn
      |> Plug.Conn.get_req_header(state.session_header)
      |> List.first()
      |> Kernel.||(state.session_id)

    %{
      transport: :streamable_http,
      type: :server,
      session_id: session_id,
      remote_ip: conn.remote_ip,
      request_path: conn.request_path
    }
  end

  def extract_metadata(headers, state) when is_list(headers) do
    session_id = find_header(headers, state.session_header) || state.session_id

    %{
      transport: :streamable_http,
      type: :server,
      session_id: session_id
    }
  end

  def extract_metadata(_raw_input, state) do
    %{
      transport: :streamable_http,
      type: :server,
      session_id: state.session_id
    }
  end

  defp find_header(headers, name) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == String.downcase(name), do: value

      _ ->
        nil
    end)
  end

  @typedoc """
  StreamableHTTP transport options

  - `:server` - The server module (required)
  - `:name` - Name for registering the GenServer (required)
  """
  @type option ::
          {:server, GenServer.server()}
          | {:name, GenServer.name()}
          | GenServer.option()

  defschema(:parse_options, [
    {:server, {:required, Anubis.get_schema(:process_name)}},
    {:name, {:required, {:custom, &Anubis.genserver_name/1}}},
    {:registry, {:atom, {:default, Anubis.Server.Registry}}},
    {:task_supervisor, {:required, {:custom, &Anubis.genserver_name/1}}},
    {:keepalive, {:boolean, {:default, true}}},
    {:keepalive_interval, {:integer, {:default, 5_000}}}
  ])

  @impl Transport
  @spec start_link(Enumerable.t(option())) :: GenServer.on_start()
  def start_link(opts) do
    opts = parse_options!(opts)
    {name, opts} = Keyword.pop!(opts, :name)

    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @impl Transport
  def send_message(transport, message, opts) when is_binary(message) do
    GenServer.call(transport, {:send_message, message}, opts[:timeout])
  end

  @impl Transport
  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(transport) do
    GenServer.cast(transport, :shutdown)
  end

  @impl Transport
  def supported_protocol_versions, do: ["2025-03-26", "2025-06-18"]

  @doc """
  Registers the calling process as the SSE handler for a session.

  Called by the Plug when establishing an SSE connection.
  """
  @spec register_sse_handler(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def register_sse_handler(transport, session_id) do
    GenServer.call(transport, {:register_sse_handler, session_id, self()}, 5000)
  end

  @doc """
  Unregisters the SSE handler for a session. Called when the SSE connection closes.
  """
  @spec unregister_sse_handler(GenServer.server(), String.t(), pid() | nil) :: :ok
  def unregister_sse_handler(transport, session_id, expected_pid \\ nil) do
    GenServer.cast(transport, {:unregister_sse_handler, session_id, expected_pid})
  end

  @doc """
  Returns the SSE handler pid for a session, or `nil` if none is connected.
  """
  @spec get_sse_handler(GenServer.server(), String.t()) :: pid() | nil
  def get_sse_handler(transport, session_id) do
    GenServer.call(transport, {:get_sse_handler, session_id})
  end

  @doc """
  Routes a message to a specific session's SSE handler for server-to-client push.
  """
  @spec route_to_session(GenServer.server(), String.t(), binary()) ::
          :ok | {:error, term()}
  def route_to_session(transport, session_id, message) do
    GenServer.call(transport, {:route_to_session, session_id, message})
  end

  # GenServer implementation

  @impl GenServer
  def init(%{server: server} = opts) do
    Process.flag(:trap_exit, true)

    state = %{
      server: server,
      registry: opts.registry,
      task_supervisor: opts.task_supervisor,
      sse_handlers: %{},
      keepalive_interval: opts.keepalive_interval,
      keepalive_enabled: opts.keepalive
    }

    if should_keepalive?(state) do
      schedule_keepalive(state.keepalive_interval)
    end

    Logger.metadata(mcp_transport: :streamable_http, mcp_server: server)

    Logging.transport_event("starting", %{
      transport: :streamable_http,
      server: server
    })

    Telemetry.execute(
      Telemetry.event_transport_init(),
      %{system_time: System.system_time()},
      %{transport: :streamable_http, server: server}
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:register_sse_handler, session_id, pid}, _from, state) do
    sse_handlers =
      case Map.get(state.sse_handlers, session_id) do
        {^pid, old_ref} ->
          Process.demonitor(old_ref, [:flush])
          state.sse_handlers

        {old_pid, old_ref} ->
          Process.demonitor(old_ref, [:flush])
          send(old_pid, :close_sse)
          state.sse_handlers

        nil ->
          state.sse_handlers
      end

    ref = Process.monitor(pid)
    sse_handlers = Map.put(sse_handlers, session_id, {pid, ref})

    Logging.transport_event("sse_handler_registered", %{
      session_id: session_id,
      handler_pid: inspect(pid)
    })

    {:reply, :ok, %{state | sse_handlers: sse_handlers}}
  end

  @impl GenServer
  def handle_call({:get_sse_handler, session_id}, _from, state) do
    case Map.get(state.sse_handlers, session_id) do
      {pid, _ref} -> {:reply, pid, state}
      nil -> {:reply, nil, state}
    end
  end

  @impl GenServer
  def handle_call({:route_to_session, session_id, message}, _from, state) do
    case Map.get(state.sse_handlers, session_id) do
      {pid, _ref} ->
        send(pid, {:sse_message, message})
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :no_sse_handler}, state}
    end
  end

  @impl GenServer
  def handle_call({:send_message, message}, _from, state) do
    Logging.transport_event("broadcast_notification", %{
      message_size: byte_size(message),
      active_handlers: map_size(state.sse_handlers)
    })

    for {_session_id, {pid, _ref}} <- state.sse_handlers do
      send(pid, {:sse_message, message})
    end

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:unregister_sse_handler, session_id}, state) do
    handle_cast({:unregister_sse_handler, session_id, nil}, state)
  end

  @impl GenServer
  def handle_cast({:unregister_sse_handler, session_id, expected_pid}, state) do
    sse_handlers =
      case Map.get(state.sse_handlers, session_id) do
        {pid, _ref} when is_pid(expected_pid) and pid != expected_pid ->
          state.sse_handlers

        {_pid, ref} ->
          Process.demonitor(ref, [:flush])
          Map.delete(state.sse_handlers, session_id)

        nil ->
          state.sse_handlers
      end

    {:noreply, %{state | sse_handlers: sse_handlers}}
  end

  @impl GenServer
  def handle_cast(:shutdown, state) do
    Logging.transport_event("shutdown", %{transport: :streamable_http}, level: :info)

    for {_session_id, {pid, _ref}} <- state.sse_handlers do
      send(pid, :close_sse)
    end

    Telemetry.execute(
      Telemetry.event_transport_disconnect(),
      %{system_time: System.system_time()},
      %{transport: :streamable_http, reason: :shutdown}
    )

    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    sse_handlers =
      state.sse_handlers
      |> Enum.reject(fn {_session_id, {handler_pid, monitor_ref}} ->
        handler_pid == pid and monitor_ref == ref
      end)
      |> Map.new()

    if map_size(sse_handlers) < map_size(state.sse_handlers) do
      Logging.transport_event("sse_handler_down", %{reason: inspect(reason)})
    end

    {:noreply, %{state | sse_handlers: sse_handlers}}
  end

  def handle_info(:send_keepalive, state) do
    for {_session_id, {pid, _ref}} <- state.sse_handlers do
      send(pid, :sse_keepalive)
    end

    if should_keepalive?(state) do
      schedule_keepalive(state.keepalive_interval)
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logging.transport_event("unknown handle_info message", msg, level: :warning)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, _state) do
    Telemetry.execute(
      Telemetry.event_transport_terminate(),
      %{system_time: System.system_time()},
      %{transport: :streamable_http, reason: reason}
    )

    :ok
  end

  defp schedule_keepalive(interval) do
    Process.send_after(self(), :send_keepalive, interval)
  end

  defp should_keepalive?(state) do
    state.keepalive_enabled and not Enum.empty?(state.sse_handlers)
  end
end
