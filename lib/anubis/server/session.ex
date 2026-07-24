defmodule Anubis.Server.Session do
  @moduledoc """
  Per-client MCP session process.

  Each Session is a GenServer that manages the lifecycle of a single MCP client
  connection. It handles protocol initialization, request/notification dispatch,
  server-initiated requests (sampling, roots), and session persistence.

  Sessions are created by the transport layer (STDIO creates one at startup,
  HTTP transports create them dynamically via `Anubis.Server.Supervisor`).
  """

  use GenServer
  use Anubis.Logging

  import Peri

  alias Anubis.MCP.ElicitationSchema
  alias Anubis.MCP.Error
  alias Anubis.MCP.ID
  alias Anubis.MCP.Message
  alias Anubis.Server
  alias Anubis.Server.Context
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers
  alias Anubis.Server.Handlers.Tasks, as: TasksHandler
  alias Anubis.Server.Task, as: McpTask
  alias Anubis.Telemetry

  require Message
  require Server

  @default_session_idle_timeout to_timeout(minute: 30)
  @default_task_ttl 60_000
  @max_task_ttl to_timeout(hour: 1)
  @min_task_ttl 1_000
  @default_task_poll_interval 1_000

  @type task_waiter :: {from :: GenServer.from(), request_id :: String.t() | integer()}

  @type task_runtime :: %{
          worker_ref: reference() | nil,
          worker_pid: pid() | nil,
          ttl_timer: reference() | nil,
          waiters: [task_waiter()],
          request_id: String.t() | integer()
        }

  @type t :: %{
          session_id: String.t(),
          server_module: module(),
          protocol_version: String.t() | nil,
          protocol_module: module() | nil,
          initialized: boolean(),
          client_info: map() | nil,
          client_capabilities: map() | nil,
          init_meta: map(),
          log_level: String.t() | nil,
          frame: Frame.t(),
          server_info: map(),
          capabilities: map(),
          instructions: String.t() | nil,
          supported_versions: list(String.t()),
          transport: %{layer: module(), name: GenServer.name()},
          registry: module(),
          session_idle_timeout: pos_integer(),
          expiry_timer: reference() | nil,
          pending_requests: %{
            String.t() => %{started_at: integer(), method: String.t()}
          },
          server_requests: %{
            String.t() => %{
              method: String.t(),
              timer_ref: reference()
            }
          },
          timeout: pos_integer(),
          task_supervisor: GenServer.name(),
          task_store: %{adapter: module(), name: term()} | nil,
          tasks: %{String.t() => task_runtime()},
          task_refs: %{reference() => String.t()},
          in_flight:
            nil
            | %{
                ref: reference(),
                pid: pid(),
                request_id: String.t(),
                from: GenServer.from(),
                started_at: integer(),
                method: String.t()
              },
          request_queue: :queue.queue({map(), map(), GenServer.from()}),
          deferred_callbacks: :queue.queue({:cast | :info, term()})
        }

  defschema(:parse_options, [
    {:session_id, {:required, :string}},
    {:server_module, {:required, :atom}},
    {:name, {:required, {:custom, &Anubis.genserver_name/1}}},
    {:transport, {:required, {:custom, &Anubis.server_transport/1}}},
    {:registry, {:atom, {:default, Anubis.Server.Registry}}},
    {:session_idle_timeout, {{:integer, {:gte, 1}}, {:default, @default_session_idle_timeout}}},
    {:timeout, {:integer, {:default, to_timeout(second: 30)}}},
    {:task_supervisor, {:required, {:custom, &Anubis.genserver_name/1}}},
    {:task_store,
     {[adapter: {:required, :atom}, name: {:required, {:custom, &Anubis.genserver_name/1}}], {:default, nil}}},
    {:pre_initialized, {:boolean, {:default, false}}}
  ])

  @doc """
  Starts a Session process linked to the current process.

  ## Options

    * `:session_id` — unique session identifier (required)
    * `:server_module` — the MCP server module implementing `Anubis.Server` (required)
    * `:name` — GenServer registration name (required)
    * `:transport` — transport configuration `[layer: module, name: name]` (required)
    * `:task_supervisor` — name of the `Task.Supervisor` for async work (required)
    * `:registry` — session registry module (default: `Anubis.Server.Registry`)
    * `:session_idle_timeout` — idle timeout in ms before session expires (default: 30 min)
    * `:timeout` — request timeout in ms (default: 30s)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = parse_options!(opts)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Auto-initializes a session without a client initialize handshake.

  This is used when a client sends a non-initialize request to an expired or
  unknown session. Instead of returning 404, the server can create a new session
  and auto-initialize it so the request can be processed transparently.

  Uses the server's latest supported protocol version and synthetic client info
  (`%{"name" => "auto-recovered", "version" => "unknown"}`). Server implementations
  should not rely on this identity for client-specific decisions.
  """
  @spec auto_initialize(GenServer.server()) :: :ok | {:error, term()}
  def auto_initialize(session), do: auto_initialize(session, nil)

  @spec auto_initialize(GenServer.server(), map() | nil) :: :ok | {:error, term()}
  def auto_initialize(session, transport_context) do
    GenServer.call(session, {:auto_initialize, transport_context})
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  # Lifecycle

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    module = opts.server_module
    server_info = module.server_info()
    capabilities = module.server_capabilities()
    protocol_versions = module.supported_protocol_versions()
    instructions = module.server_instructions()

    state = %{
      session_id: opts.session_id,
      server_module: module,
      protocol_version: nil,
      protocol_module: nil,
      initialized: opts.pre_initialized,
      client_info: nil,
      client_capabilities: nil,
      init_meta: %{},
      log_level: nil,
      frame: Frame.new(),
      server_info: server_info,
      capabilities: capabilities,
      instructions: instructions,
      supported_versions: protocol_versions,
      transport: Map.new(opts.transport),
      registry: opts.registry,
      session_idle_timeout: opts.session_idle_timeout,
      expiry_timer: nil,
      pending_requests: %{},
      server_requests: %{},
      timeout: opts.timeout,
      task_supervisor: opts.task_supervisor,
      task_store: build_task_store(opts[:task_store]),
      tasks: %{},
      task_refs: %{},
      in_flight: nil,
      request_queue: :queue.new(),
      deferred_callbacks: :queue.new()
    }

    state = schedule_session_expiry(state)
    maybe_schedule_store_ttl_refresh()

    Logging.server_event("session_starting", %{
      session_id: opts.session_id,
      module: module,
      server_info: server_info
    })

    Telemetry.execute(
      Telemetry.event_server_init(),
      %{system_time: System.system_time()},
      %{
        module: module,
        server_info: server_info,
        capabilities: capabilities,
        session_id: opts.session_id
      }
    )

    {:ok, state, :hibernate}
  end

  # Request/Response handling

  @impl GenServer
  def handle_call({:mcp_request, decoded, transport_context}, from, state) when is_map(decoded) do
    state = merge_transport_assigns(state, transport_context)
    state = reset_session_expiry(state)

    handle_single_request(decoded, transport_context, from, state)
  end

  def handle_call({:auto_initialize, _transport_context}, _from, %{initialized: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:auto_initialize, transport_context}, _from, %{server_module: module} = state) do
    with [latest_version | _] <- state.supported_versions,
         {:ok, protocol_version, protocol_module} <-
           Anubis.Protocol.Registry.negotiate(latest_version, state.supported_versions) do
      {restored_client_info, restored_frame, restored_init_meta} = maybe_restore_from_store(state.session_id)

      auto_state = %{
        state
        | protocol_version: protocol_version,
          protocol_module: protocol_module,
          client_info: restored_client_info || %{"name" => "auto-recovered", "version" => "unknown"},
          client_capabilities: %{},
          init_meta: restored_init_meta,
          initialized: true,
          frame: restored_frame || state.frame
      }

      auto_state = put_recovery_assigns(auto_state, transport_context)
      frame = prepare_frame(auto_state, transport_context)

      case maybe_call_session_expired(module, auto_state.session_id, frame) do
        {:ok, frame} ->
          do_complete_auto_init(auto_state, frame, protocol_version)

        {:ok, client_info, frame} ->
          do_complete_auto_init(%{auto_state | client_info: client_info}, frame, protocol_version)

        {:error, reason} ->
          Logging.server_event("session_recovery_rejected", %{
            session_id: auto_state.session_id,
            reason: inspect(reason)
          })

          {:reply, {:error, Error.wrap_reason(reason)}, state}

        :default ->
          fallback_to_init(module, auto_state, frame, protocol_version, state)
      end
    else
      [] -> {:reply, {:error, :no_supported_versions}, state}
      :error -> {:reply, {:error, :negotiate_failed}, state}
    end
  end

  def handle_call(request, from, %{server_module: module} = state) do
    if Anubis.exported?(module, :handle_call, 3) do
      frame = prepare_frame(state)

      case module.handle_call(request, from, frame) do
        {:reply, reply, frame} ->
          {:reply, reply, %{state | frame: frame}}

        {:reply, reply, frame, cont} ->
          {:reply, reply, %{state | frame: frame}, cont}

        {:noreply, frame} ->
          {:noreply, %{state | frame: frame}}

        {:noreply, frame, cont} ->
          {:noreply, %{state | frame: frame}, cont}

        {:stop, reason, reply, frame} ->
          {:stop, reason, reply, %{state | frame: frame}}

        {:stop, reason, frame} ->
          {:stop, reason, %{state | frame: frame}}
      end
    else
      {:reply, {:error, :not_implemented}, state}
    end
  end

  # Notification dispatch

  @impl GenServer
  def handle_cast({:mcp_notification, decoded, _ctx} = msg, %{in_flight: f} = state)
      when not is_nil(f) and is_map(decoded) do
    if cancellation_notification?(decoded) do
      process_mcp_notification(msg, state)
    else
      {:noreply, defer_callback(state, {:cast, msg})}
    end
  end

  def handle_cast({:mcp_notification, decoded, _ctx} = msg, state) when is_map(decoded) do
    process_mcp_notification(msg, state)
  end

  # Server-initiated request responses (sampling/roots)

  def handle_cast({:mcp_response, decoded, _ctx} = msg, %{in_flight: f} = state) when not is_nil(f) and is_map(decoded) do
    {:noreply, defer_callback(state, {:cast, msg})}
  end

  def handle_cast({:mcp_response, decoded, _context}, state) when is_map(decoded) do
    process_mcp_response(decoded, state)
  end

  def handle_cast(request, %{in_flight: f} = state) when not is_nil(f) do
    {:noreply, defer_callback(state, {:cast, request})}
  end

  def handle_cast(request, state) do
    process_user_cast(request, state)
  end

  defp process_mcp_notification({:mcp_notification, decoded, transport_context}, state) do
    state = merge_transport_assigns(state, transport_context)
    state = reset_session_expiry(state)

    if Message.is_initialize_lifecycle(decoded) or state.initialized do
      handle_notification(decoded, transport_context, state)
    else
      Logging.server_event("session_not_initialized_check", %{
        session_id: state.session_id,
        initialized: state.initialized,
        method: decoded["method"]
      })

      {:noreply, state}
    end
  end

  defp process_mcp_response(decoded, state) do
    cond do
      Message.is_response(decoded) and server_request?(decoded["id"], state) ->
        handle_server_request_response(decoded, state)

      Message.is_error(decoded) and server_request?(decoded["id"], state) ->
        handle_server_request_error(decoded, state)

      true ->
        Logging.server_event(
          "unexpected_response",
          %{message: decoded},
          level: :warning
        )

        {:noreply, state}
    end
  end

  defp cancellation_notification?(%{"method" => "notifications/cancelled"} = msg), do: Message.is_notification(msg)

  defp cancellation_notification?(_), do: false

  defp process_user_cast(request, %{server_module: module} = state) do
    if Anubis.exported?(module, :handle_cast, 2) do
      frame = prepare_frame(state)

      case module.handle_cast(request, frame) do
        {:noreply, frame} -> {:noreply, %{state | frame: frame}}
        {:noreply, frame, cont} -> {:noreply, %{state | frame: frame}, cont}
        {:stop, reason, frame} -> {:stop, reason, %{state | frame: frame}}
      end
    else
      {:noreply, state}
    end
  end

  defp process_user_info(event, %{server_module: module} = state) do
    if Anubis.exported?(module, :handle_info, 2) do
      frame = prepare_frame(state)

      case module.handle_info(event, frame) do
        {:noreply, frame} -> {:noreply, %{state | frame: frame}}
        {:noreply, frame, cont} -> {:noreply, %{state | frame: frame}, cont}
        {:stop, reason, frame} -> {:stop, reason, %{state | frame: frame}}
      end
    else
      {:noreply, state}
    end
  end

  # Handle info messages

  @impl GenServer
  def handle_info({:send_notification, method, params}, state) do
    with {:ok, notification} <- encode_notification(method, params),
         :ok <- send_to_transport(state.transport, notification, transport_opts(state)) do
      {:noreply, state}
    else
      {:error, err} ->
        Logging.server_event("failed_send_notification", %{method: method, error: err}, level: :error)

        {:noreply, state}
    end
  end

  def handle_info({:send_resource_update, uri, params}, state) do
    subscribed? = Frame.resource_subscribed?(state.frame, uri)

    if subscribed? do
      send(self(), {:send_notification, "notifications/resources/updated", params})
    end

    {:noreply, state}
  end

  def handle_info(:session_expired, state) do
    Logging.server_event("session_expired", %{session_id: state.session_id})
    {:stop, {:shutdown, :session_expired}, state}
  end

  def handle_info(:refresh_store_ttl, state) do
    refresh_store_ttl(state)
    maybe_schedule_store_ttl_refresh()
    {:noreply, state}
  end

  def handle_info({:send_sampling_request, params, timeout}, state) do
    request_id = ID.generate_request_id()
    handle_sampling_request_send(request_id, params, timeout, state)
  end

  def handle_info({:sampling_request_timeout, request_id}, state) do
    handle_sampling_timeout(request_id, state)
  end

  def handle_info({:send_roots_request, timeout}, state) do
    request_id = ID.generate_request_id()
    handle_roots_request_send(request_id, timeout, state)
  end

  def handle_info({:roots_request_timeout, request_id}, state) do
    handle_roots_timeout(request_id, state)
  end

  def handle_info({:send_elicitation_request, params, requested_schema, timeout}, state) do
    request_id = ID.generate_request_id()
    handle_elicitation_request_send(request_id, params, requested_schema, timeout, state)
  end

  def handle_info({:elicitation_request_timeout, request_id}, state) do
    handle_elicitation_timeout(request_id, state)
  end

  def handle_info({ref, callback_result}, %{in_flight: %{ref: ref} = inflight} = state) do
    Process.demonitor(ref, [:flush])
    {reply, state} = decode_task_result(callback_result, inflight, state)
    state = complete_request(%{state | in_flight: nil}, inflight.request_id)
    GenServer.reply(inflight.from, reply)

    finalize_after_task(state)
  end

  def handle_info({ref, callback_result}, state) when is_reference(ref) do
    case task_id_for_ref(state, ref) do
      nil ->
        {:noreply, state}

      task_id ->
        Process.demonitor(ref, [:flush])
        handle_task_worker_completion(task_id, callback_result, state)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    cond do
      task_id = task_id_for_ref(state, ref) ->
        handle_task_worker_down(task_id, reason, state)

      state.in_flight && state.in_flight.ref == ref ->
        handle_in_flight_down(reason, state)

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:task_expired, task_id}, state) do
    handle_task_expired(task_id, state)
  end

  def handle_info({:send_task_status, task_id}, state) do
    _ = emit_task_status_notification(state, task_id)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(event, %{in_flight: f} = state) when not is_nil(f) do
    {:noreply, defer_callback(state, {:info, event})}
  end

  def handle_info(event, state) do
    process_user_info(event, state)
  end

  defp handle_in_flight_down(reason, %{in_flight: inflight} = state) do
    Logging.server_event(
      "request_task_crashed",
      %{request_id: inflight.request_id, method: inflight.method, reason: inspect(reason)},
      level: :error
    )

    Telemetry.execute(
      Telemetry.event_server_error(),
      %{system_time: System.system_time()},
      %{id: inflight.request_id, method: inflight.method, error: reason}
    )

    error = Error.protocol(:internal_error, %{message: "Tool execution crashed"})
    reply = {:ok, encode_reply(Error.build_json_rpc(error, inflight.request_id))}

    state = complete_request(%{state | in_flight: nil}, inflight.request_id)
    GenServer.reply(inflight.from, reply)

    finalize_after_task(state)
  end

  @impl GenServer
  def terminate(reason, %{server_module: module, server_info: server_info} = state) do
    cancel_session_expiry(state)
    reply_to_pending_callers(state, reason)

    Logging.server_event("session_terminating", %{
      session_id: state.session_id,
      reason: reason,
      server_info: server_info
    })

    Telemetry.execute(
      Telemetry.event_server_terminate(),
      %{system_time: System.system_time()},
      %{reason: reason, server_info: server_info, session_id: state.session_id}
    )

    if Anubis.exported?(module, :terminate, 2) do
      frame = prepare_frame(state)
      module.terminate(reason, frame)
    else
      :ok
    end
  end

  defp reply_to_pending_callers(
         %{in_flight: in_flight, request_queue: q, task_supervisor: task_supervisor, tasks: tasks},
         reason
       ) do
    error =
      Error.protocol(:internal_error, %{
        message: "Session terminating",
        reason: inspect(reason)
      })

    if in_flight do
      Task.Supervisor.terminate_child(task_supervisor, in_flight.pid)
      Process.demonitor(in_flight.ref, [:flush])
      flush_task_reply(in_flight.ref)

      reply = {:ok, encode_reply(Error.build_json_rpc(error, in_flight.request_id))}
      GenServer.reply(in_flight.from, reply)
    end

    Enum.each(:queue.to_list(q), fn {%{"id" => request_id}, _ctx, from} ->
      reply = {:ok, encode_reply(Error.build_json_rpc(error, request_id))}
      GenServer.reply(from, reply)
    end)

    Enum.each(tasks, fn {_task_id, %{worker_pid: pid, worker_ref: ref} = runtime} ->
      if pid, do: Task.Supervisor.terminate_child(task_supervisor, pid)
      if ref, do: Process.demonitor(ref, [:flush])
      release_waiters(runtime, error)
    end)
  end

  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:state, state} ->
        {:state, format_state(state)}

      {:message, {:mcp_request, decoded, _ctx}} ->
        {:message, {:mcp_request, decoded}}

      {:message, {:mcp_notification, decoded, _ctx}} ->
        {:message, {:mcp_notification, decoded}}

      {:message, {:mcp_response, decoded, _ctx}} ->
        {:message, {:mcp_response, decoded}}

      other ->
        other
    end)
  end

  # Request handling

  defguardp is_server_initialized(decoded, state)
            when Message.is_initialize_lifecycle(decoded) or
                   state.initialized == true

  defp handle_single_request(decoded, transport_context, from, state) do
    cond do
      Message.is_response(decoded) and server_request?(decoded["id"], state) ->
        {:noreply, new_state} = handle_server_request_response(decoded, state)
        {:reply, {:ok, nil}, new_state}

      Message.is_error(decoded) and server_request?(decoded["id"], state) ->
        {:noreply, new_state} = handle_server_request_error(decoded, state)
        {:reply, {:ok, nil}, new_state}

      Message.is_ping(decoded) ->
        handle_server_ping(decoded, state)

      not is_server_initialized(decoded, state) ->
        handle_server_not_initialized(decoded, state)

      Message.is_request(decoded) ->
        handle_request(decoded, transport_context, from, state)

      true ->
        handle_invalid_request(state)
    end
  end

  defp handle_server_ping(%{"id" => request_id}, state) do
    {:reply, {:ok, encode_reply(Message.build_response(%{}, request_id))}, state}
  end

  defp handle_server_not_initialized(decoded, state) do
    error = Error.protocol(:invalid_request, %{message: "Server not initialized"})

    Logging.server_event(
      "request_error",
      %{error: error, reason: "not_initialized"},
      level: :warning
    )

    {:reply, {:ok, encode_reply(Error.build_json_rpc(error, decoded["id"]))}, state}
  end

  defp handle_invalid_request(state) do
    error =
      Error.protocol(:invalid_request, %{
        message: "Expected request but got different message type"
      })

    {:reply, {:error, error}, state}
  end

  # Initialize handling

  defp handle_request(%{"params" => params} = request, _transport_context, _from, state)
       when Message.is_initialize(request) do
    %{
      "clientInfo" => client_info,
      "capabilities" => client_capabilities,
      "protocolVersion" => requested_version
    } = params

    {:ok, protocol_version, protocol_module} =
      Anubis.Protocol.Registry.negotiate(requested_version, state.supported_versions)

    state = %{
      state
      | protocol_version: protocol_version,
        protocol_module: protocol_module,
        client_info: client_info,
        client_capabilities: client_capabilities,
        init_meta: Map.get(params, "_meta", %{}),
        initialized: true
    }

    maybe_persist_session(state)

    result =
      maybe_put_instructions(
        %{"protocolVersion" => protocol_version, "serverInfo" => state.server_info, "capabilities" => state.capabilities},
        state.instructions
      )

    Logging.server_event("initializing", %{
      client_info: client_info,
      client_capabilities: client_capabilities,
      protocol_version: protocol_version,
      session_id: state.session_id
    })

    Telemetry.execute(
      Telemetry.event_server_response(),
      %{system_time: System.system_time()},
      %{method: "initialize", status: :success}
    )

    {:reply, {:ok, encode_reply(Message.build_response(result, request["id"]))}, state}
  end

  defp handle_request(%{"id" => request_id, "method" => "logging/setLevel"} = request, _transport_context, _from, state)
       when Server.is_supported_capability(state.capabilities, "logging") do
    level = request["params"]["level"]
    state = %{state | log_level: level}
    {:reply, {:ok, encode_reply(Message.build_response(%{}, request_id))}, state}
  end

  defp handle_request(%{"method" => "tasks/" <> _} = request, ctx, from, state) do
    dispatch_tasks_request(request, ctx, from, state)
  end

  defp handle_request(%{"method" => "tools/call"} = request, ctx, from, state) do
    if task_augmented_tools_call?(request) do
      create_task_for_tools_call(request, ctx, from, state)
    else
      enqueue_or_dispatch(request, ctx, from, state)
    end
  end

  defp handle_request(%{"id" => _, "method" => _} = request, transport_context, from, state) do
    enqueue_or_dispatch(request, transport_context, from, state)
  end

  defp enqueue_or_dispatch(request, ctx, from, %{in_flight: nil} = state) do
    {:noreply, dispatch_request(request, ctx, from, state)}
  end

  defp enqueue_or_dispatch(request, ctx, from, state) do
    {:noreply, %{state | request_queue: :queue.in({request, ctx, from}, state.request_queue)}}
  end

  defp dispatch_request(%{"id" => request_id, "method" => method} = request, transport_context, from, state) do
    Logging.server_event("handling_request", %{
      id: request_id,
      method: method,
      session_id: state.session_id
    })

    state = track_request(state, request_id, method)

    Telemetry.execute(
      Telemetry.event_server_request(),
      %{system_time: System.system_time()},
      %{id: request_id, method: method}
    )

    frame = prepare_frame(state, transport_context)
    module = state.server_module

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        do_handle_request(module, request, frame, method)
      end)

    %{
      state
      | in_flight: %{
          ref: task.ref,
          pid: task.pid,
          request_id: request_id,
          from: from,
          started_at: System.monotonic_time(:millisecond),
          method: method
        }
    }
  end

  defp flush_task_reply(ref) do
    receive do
      {^ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp do_handle_request(module, %{"method" => "tools/call"} = request, frame, _method) do
    tool_name = get_in(request, ["params", "name"])

    :telemetry.span(
      Telemetry.event_server_tool_call(),
      %{tool: tool_name},
      fn -> {module.handle_request(request, frame), %{tool: tool_name}} end
    )
  end

  defp do_handle_request(module, request, frame, _method) do
    module.handle_request(request, frame)
  end

  # Async dispatch helpers

  defp decode_task_result({:reply, response, %Frame{} = frame}, inflight, state) do
    Telemetry.execute(
      Telemetry.event_server_response(),
      %{system_time: System.system_time()},
      %{id: inflight.request_id, method: inflight.method, status: :success}
    )

    reply = {:ok, encode_reply(Message.build_response(response, inflight.request_id))}
    {reply, %{state | frame: frame}}
  end

  defp decode_task_result({:noreply, %Frame{} = frame}, inflight, state) do
    Telemetry.execute(
      Telemetry.event_server_response(),
      %{system_time: System.system_time()},
      %{id: inflight.request_id, method: inflight.method, status: :noreply}
    )

    {{:ok, nil}, %{state | frame: frame}}
  end

  defp decode_task_result({:error, %Error{} = error, %Frame{} = frame}, inflight, state) do
    Logging.server_event(
      "request_error",
      %{id: inflight.request_id, method: inflight.method, error: error},
      level: :warning
    )

    Telemetry.execute(
      Telemetry.event_server_error(),
      %{system_time: System.system_time()},
      %{id: inflight.request_id, method: inflight.method, error: error}
    )

    reply = {:ok, encode_reply(Error.build_json_rpc(error, inflight.request_id))}
    {reply, %{state | frame: frame}}
  end

  defp decode_task_result(other, inflight, state) do
    Logging.server_event(
      "invalid_handle_request_return",
      %{id: inflight.request_id, method: inflight.method, returned: inspect(other)},
      level: :error
    )

    Telemetry.execute(
      Telemetry.event_server_error(),
      %{system_time: System.system_time()},
      %{id: inflight.request_id, method: inflight.method, error: :invalid_return}
    )

    error = Error.protocol(:internal_error, %{message: "Invalid handler return value"})
    reply = {:ok, encode_reply(Error.build_json_rpc(error, inflight.request_id))}
    {reply, state}
  end

  defp defer_callback(state, item) do
    %{state | deferred_callbacks: :queue.in(item, state.deferred_callbacks)}
  end

  defp drain_deferred_callbacks(%{deferred_callbacks: q} = state) do
    state = %{state | deferred_callbacks: :queue.new()}

    Enum.reduce_while(:queue.to_list(q), state, fn item, acc ->
      case apply_deferred(item, acc) do
        {:noreply, new_state} -> {:cont, new_state}
        {:noreply, new_state, _cont} -> {:cont, new_state}
        {:stop, _reason, _new_state} = stop -> {:halt, stop}
      end
    end)
  end

  defp apply_deferred({:cast, {:mcp_notification, _, _} = msg}, state), do: process_mcp_notification(msg, state)
  defp apply_deferred({:cast, {:mcp_response, decoded, _ctx}}, state), do: process_mcp_response(decoded, state)
  defp apply_deferred({:cast, msg}, state), do: process_user_cast(msg, state)
  defp apply_deferred({:info, msg}, state), do: process_user_info(msg, state)

  defp finalize_after_task(state) do
    case drain_deferred_callbacks(state) do
      {:stop, _reason, _new_state} = stop -> stop
      new_state -> new_state |> dispatch_next_queued() |> noreply()
    end
  end

  defp dispatch_next_queued(%{request_queue: q} = state) do
    case :queue.out(q) do
      {:empty, _} ->
        state

      {{:value, {request, ctx, from}}, rest} ->
        dispatch_request(request, ctx, from, %{state | request_queue: rest})
    end
  end

  defp noreply(state), do: {:noreply, state}

  # Notification handling

  defp handle_notification(
         %{"method" => "notifications/initialized"},
         _transport_context,
         %{server_module: module} = state
       ) do
    Logging.server_event("client_initialized", %{session_id: state.session_id})

    state = %{state | initialized: true}

    maybe_persist_session(state)

    Logging.server_event("session_marked_initialized", %{
      session_id: state.session_id,
      initialized: true
    })

    frame = prepare_frame(state)

    {:ok, frame} =
      if Anubis.exported?(module, :init, 2),
        do: module.init(state.client_info, frame),
        else: {:ok, frame}

    {:noreply, %{state | frame: frame}}
  end

  defp handle_notification(%{"method" => "notifications/cancelled"} = notification, _transport_context, state) do
    params = notification["params"] || %{}
    request_id = params["requestId"]
    reason = Map.get(params, "reason", "cancelled")

    cond do
      in_flight?(state, request_id) ->
        cancel_in_flight(state, request_id, reason)

      queued?(state, request_id) ->
        cancel_queued(state, request_id, reason)

      true ->
        Logging.server_event("cancellation_for_unknown_request", %{
          session_id: state.session_id,
          request_id: request_id,
          reason: reason
        })

        {:noreply, state}
    end
  end

  defp handle_notification(notification, _transport_context, state) do
    method = notification["method"]

    Logging.server_event("handling_notification", %{method: method})

    Telemetry.execute(
      Telemetry.event_server_notification(),
      %{system_time: System.system_time()},
      %{method: method}
    )

    frame = prepare_frame(state)
    server_notification(notification, %{state | frame: frame})
  end

  defp in_flight?(%{in_flight: %{request_id: rid}}, rid), do: true
  defp in_flight?(_, _), do: false

  defp queued?(%{request_queue: q}, rid) do
    Enum.any?(:queue.to_list(q), fn {%{"id" => id}, _ctx, _from} -> id == rid end)
  end

  defp cancel_in_flight(%{in_flight: inflight} = state, request_id, reason) do
    Task.Supervisor.terminate_child(state.task_supervisor, inflight.pid)
    Process.demonitor(inflight.ref, [:flush])
    flush_task_reply(inflight.ref)

    Logging.server_event("request_cancelled", %{
      session_id: state.session_id,
      request_id: request_id,
      reason: reason,
      method: inflight.method,
      duration_ms: System.monotonic_time(:millisecond) - inflight.started_at
    })

    emit_cancellation_telemetry(state.session_id, request_id)

    error = Error.execution("Request cancelled", %{reason: reason})
    reply = {:ok, encode_reply(Error.build_json_rpc(error, request_id))}
    GenServer.reply(inflight.from, reply)

    state = complete_request(%{state | in_flight: nil}, request_id)
    finalize_after_task(state)
  end

  defp cancel_queued(state, request_id, reason) do
    {cancelled, kept} =
      state.request_queue
      |> :queue.to_list()
      |> Enum.split_with(fn {%{"id" => id}, _ctx, _from} -> id == request_id end)

    error = Error.execution("Request cancelled", %{reason: reason})
    reply = {:ok, encode_reply(Error.build_json_rpc(error, request_id))}

    Enum.each(cancelled, fn {_request, _ctx, from} -> GenServer.reply(from, reply) end)

    Logging.server_event("queued_request_cancelled", %{
      session_id: state.session_id,
      request_id: request_id,
      reason: reason
    })

    emit_cancellation_telemetry(state.session_id, request_id)

    {:noreply, %{state | request_queue: :queue.from_list(kept)}}
  end

  defp emit_cancellation_telemetry(session_id, request_id) do
    Telemetry.execute(
      Telemetry.event_server_notification(),
      %{system_time: System.system_time()},
      %{method: "cancelled", session_id: session_id, request_id: request_id}
    )
  end

  # Notification dispatch to user module

  defp server_notification(%{"method" => method} = notification, %{server_module: module} = state) do
    if Anubis.exported?(module, :handle_notification, 2) do
      case module.handle_notification(notification, state.frame) do
        {:noreply, %Frame{} = frame} ->
          {:noreply, %{state | frame: frame}}

        {:error, _error, %Frame{} = frame} ->
          Logging.server_event(
            "notification_handler_error",
            %{method: method},
            level: :warning
          )

          {:noreply, %{state | frame: frame}}
      end
    else
      {:noreply, state}
    end
  end

  # Request tracking

  defp track_request(state, request_id, method) do
    request_info = %{
      started_at: System.system_time(:millisecond),
      method: method
    }

    %{state | pending_requests: Map.put(state.pending_requests, request_id, request_info)}
  end

  defp complete_request(state, request_id) do
    %{state | pending_requests: Map.delete(state.pending_requests, request_id)}
  end

  # Frame management

  defp prepare_frame(state, transport_context \\ nil) do
    headers =
      case transport_context do
        %{req_headers: req_headers} -> normalize_headers(req_headers)
        _ -> %{}
      end

    remote_ip =
      case transport_context do
        %{remote_ip: ip} -> ip
        _ -> nil
      end

    auth =
      case transport_context do
        %{auth: claims} -> claims
        _ -> nil
      end

    context = %Context{
      session_id: state.session_id,
      client_info: state.client_info,
      init_meta: state.init_meta,
      headers: headers,
      remote_ip: remote_ip,
      auth: auth
    }

    %{state.frame | context: context}
  end

  defp merge_transport_assigns(state, %{assigns: assigns}) when is_map(assigns) do
    original_context = state.frame.context
    frame = Frame.assign(state.frame, assigns)
    frame = %{frame | context: original_context}
    %{state | frame: frame}
  end

  defp merge_transport_assigns(state, _context), do: state

  defp put_recovery_assigns(state, %{assigns: assigns}) when is_map(assigns) and map_size(assigns) > 0 do
    %{state | frame: %{state.frame | assigns: assigns}}
  end

  defp put_recovery_assigns(state, _transport_context), do: state

  defp normalize_headers(req_headers) when is_list(req_headers) do
    Map.new(req_headers, fn {k, v} -> {String.downcase(k), v} end)
  end

  defp normalize_headers(_), do: %{}

  # Session expiry management

  defp schedule_session_expiry(%{session_idle_timeout: timeout} = state) do
    timer = Process.send_after(self(), :session_expired, timeout)
    %{state | expiry_timer: timer}
  end

  defp reset_session_expiry(state) do
    cancel_session_expiry(state)
    schedule_session_expiry(state)
  end

  defp cancel_session_expiry(%{expiry_timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    %{state | expiry_timer: nil}
  end

  # Reply encoding

  defp encode_reply(message) when is_map(message) do
    JSON.encode!(message)
  end

  # Transport helpers

  defp encode_notification(method, params) do
    notification = Message.build_notification(method, params)
    Logging.message("outgoing", "notification", nil, notification)
    Message.encode_notification(notification)
  end

  defp transport_opts(state) do
    [timeout: state.timeout, session_id: state.session_id]
  end

  defp send_to_transport(nil, _data, _opts) do
    {:error, Error.transport(:no_transport, %{message: "No transport configured"})}
  end

  defp send_to_transport(%{layer: layer, name: name}, data, opts) do
    with {:error, reason} <- layer.send_message(name, data, opts) do
      {:error, Error.transport(:send_failure, %{original_reason: reason})}
    end
  end

  # Sampling request helpers

  defp handle_sampling_request_send(request_id, params, timeout, state) do
    timer_ref =
      Process.send_after(self(), {:sampling_request_timeout, request_id}, timeout)

    request_info = %{
      method: "sampling/createMessage",
      session_id: state.session_id,
      timer_ref: timer_ref
    }

    state = put_in(state.server_requests[request_id], request_info)

    with :ok <- validate_client_capability(state, "sampling"),
         {:ok, request_data} <-
           encode_request("sampling/createMessage", params, request_id),
         :ok <- send_to_transport(state.transport, request_data, transport_opts(state)) do
      Logging.server_event("sent_sampling_request", %{request_id: request_id})
      {:noreply, state}
    else
      {:error, error} ->
        Process.cancel_timer(timer_ref)

        state = %{
          state
          | server_requests: Map.delete(state.server_requests, request_id)
        }

        Logging.server_event(
          "failed_send_sampling_request",
          %{request_id: request_id, error: error},
          level: :error
        )

        {:noreply, state}
    end
  end

  defp validate_client_capability(state, capability) do
    if Map.has_key?(state.client_capabilities || %{}, capability) do
      :ok
    else
      {:error, "Client does not support #{capability} capability"}
    end
  end

  defp handle_sampling_timeout(request_id, state) do
    case Map.pop(state.server_requests, request_id) do
      {nil, _} ->
        {:noreply, state}

      {_request_info, updated_requests} ->
        Logging.server_event("sampling_request_timeout", %{request_id: request_id}, level: :warning)

        {:noreply, %{state | server_requests: updated_requests}}
    end
  end

  defp encode_request(method, params, request_id) do
    request = %{
      "method" => method,
      "params" => params
    }

    Logging.message("outgoing", "request", request_id, request)
    Message.encode_request(request, request_id)
  end

  defp server_request?(request_id, %{server_requests: requests}) when is_binary(request_id) do
    Map.has_key?(requests, request_id)
  end

  defp server_request?(_, _), do: false

  defp handle_server_request_response(%{"id" => request_id, "result" => result}, state) do
    {request_info, updated_requests} = Map.pop(state.server_requests, request_id)
    Process.cancel_timer(request_info.timer_ref)

    state = %{state | server_requests: updated_requests}

    case request_info.method do
      "sampling/createMessage" ->
        handle_sampling(result, request_id, state)

      "roots/list" ->
        handle_roots(result["roots"] || [], request_id, state)

      "elicitation/create" ->
        handle_elicitation(result, request_id, request_info, state)

      _ ->
        {:noreply, state}
    end
  end

  defp handle_server_request_error(%{"id" => request_id, "error" => error}, state) do
    {request_info, updated_requests} = Map.pop(state.server_requests, request_id)
    Process.cancel_timer(request_info.timer_ref)

    state = %{state | server_requests: updated_requests}

    Logging.server_event(
      "server_request_error",
      %{
        request_id: request_id,
        method: request_info.method,
        error: error
      },
      level: :error
    )

    {:noreply, state}
  end

  defp handle_sampling(result, request_id, %{server_module: module} = state) do
    if Anubis.exported?(module, :handle_sampling, 3) do
      frame = prepare_frame(state)

      case module.handle_sampling(result, request_id, frame) do
        {:noreply, new_frame} ->
          {:noreply, %{state | frame: new_frame}}

        {:stop, reason, new_frame} ->
          {:stop, reason, %{state | frame: new_frame}}
      end
    else
      {:noreply, state}
    end
  end

  # Roots request helpers

  defp handle_roots_request_send(request_id, timeout, state) do
    timer_ref =
      Process.send_after(self(), {:roots_request_timeout, request_id}, timeout)

    request_info = %{
      id: request_id,
      method: "roots/list",
      session_id: state.session_id,
      timer_ref: timer_ref
    }

    state = put_in(state.server_requests[request_id], request_info)

    with :ok <- validate_client_capability(state, "roots"),
         {:ok, request_data} <- encode_request("roots/list", %{}, request_id),
         :ok <- send_to_transport(state.transport, request_data, transport_opts(state)) do
      Logging.server_event("sent_roots_request", %{request_id: request_id})
      {:noreply, state}
    else
      {:error, error} ->
        Process.cancel_timer(timer_ref)

        state = %{
          state
          | server_requests: Map.delete(state.server_requests, request_id)
        }

        Logging.server_event(
          "failed_send_roots_request",
          %{request_id: request_id, error: error},
          level: :error
        )

        {:noreply, state}
    end
  end

  defp handle_roots_timeout(request_id, state) when is_binary(request_id) do
    state.server_requests
    |> Map.pop(request_id)
    |> handle_roots_timeout(state)
  end

  defp handle_roots_timeout({nil, _}, state), do: {:noreply, state}

  defp handle_roots_timeout({%{id: request_id}, requests}, state) do
    with {:ok, notification} <-
           encode_notification("notifications/cancelled", %{
             "requestId" => request_id,
             "reason" => "timeout"
           }),
         :ok <- send_to_transport(state.transport, notification, transport_opts(state)) do
      Logging.server_event(
        "roots_request_timeout_cancelled",
        %{request_id: request_id}
      )
    end

    Logging.server_event("roots_request_timeout", %{request_id: request_id}, level: :warning)

    {:noreply, %{state | server_requests: requests}}
  end

  defp handle_roots(roots, request_id, %{server_module: module} = state) do
    if Anubis.exported?(module, :handle_roots, 3) do
      frame = prepare_frame(state)

      case module.handle_roots(roots, request_id, frame) do
        {:noreply, new_frame} ->
          {:noreply, %{state | frame: new_frame}}

        {:stop, reason, new_frame} ->
          {:stop, reason, %{state | frame: new_frame}}
      end
    else
      {:noreply, state}
    end
  end

  # Elicitation request helpers

  defp handle_elicitation_request_send(request_id, params, requested_schema, timeout, state) do
    timer_ref =
      Process.send_after(self(), {:elicitation_request_timeout, request_id}, timeout)

    request_info = %{
      id: request_id,
      method: "elicitation/create",
      session_id: state.session_id,
      timer_ref: timer_ref,
      requested_schema: requested_schema
    }

    state = put_in(state.server_requests[request_id], request_info)

    with :ok <- validate_client_capability(state, "elicitation"),
         {:ok, request_data} <-
           encode_request("elicitation/create", params, request_id),
         :ok <- send_to_transport(state.transport, request_data, transport_opts(state)) do
      Logging.server_event("sent_elicitation_request", %{request_id: request_id})
      {:noreply, state}
    else
      {:error, error} ->
        Process.cancel_timer(timer_ref)

        state = %{
          state
          | server_requests: Map.delete(state.server_requests, request_id)
        }

        Logging.server_event(
          "failed_send_elicitation_request",
          %{request_id: request_id, error: error},
          level: :error
        )

        {:noreply, state}
    end
  end

  defp handle_elicitation_timeout(request_id, state) when is_binary(request_id) do
    state.server_requests
    |> Map.pop(request_id)
    |> handle_elicitation_timeout(state)
  end

  defp handle_elicitation_timeout({nil, _}, state), do: {:noreply, state}

  defp handle_elicitation_timeout({%{id: request_id}, requests}, state) do
    with {:ok, notification} <-
           encode_notification("notifications/cancelled", %{
             "requestId" => request_id,
             "reason" => "timeout"
           }),
         :ok <- send_to_transport(state.transport, notification, transport_opts(state)) do
      Logging.server_event(
        "elicitation_request_timeout_cancelled",
        %{request_id: request_id}
      )
    end

    Logging.server_event(
      "elicitation_request_timeout",
      %{request_id: request_id},
      level: :warning
    )

    {:noreply, %{state | server_requests: requests}}
  end

  defp handle_elicitation(result, request_id, request_info, state) do
    case sanitize_elicitation_result(result, request_info) do
      {:ok, sanitized} ->
        dispatch_elicitation(sanitized, request_id, state)

      {:error, reason} ->
        Logging.server_event(
          "invalid_elicitation_response",
          %{request_id: request_id, reason: reason},
          level: :error
        )

        {:noreply, state}
    end
  end

  defp sanitize_elicitation_result(%{"action" => "accept", "content" => content} = result, %{requested_schema: schema})
       when is_map(content) do
    case ElicitationSchema.validate_content(content, schema) do
      :ok -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sanitize_elicitation_result(%{"action" => "accept"}, _info) do
    {:error, "accept action missing content"}
  end

  defp sanitize_elicitation_result(%{"action" => action} = result, _info) when action in ~w(decline cancel) do
    {:ok, result}
  end

  defp sanitize_elicitation_result(_result, _info) do
    {:error, "elicitation result missing valid action"}
  end

  defp dispatch_elicitation(result, request_id, %{server_module: module} = state) do
    if Anubis.exported?(module, :handle_elicitation, 3) do
      frame = prepare_frame(state)

      case module.handle_elicitation(result, request_id, frame) do
        {:noreply, new_frame} ->
          {:noreply, %{state | frame: new_frame}}

        {:stop, reason, new_frame} ->
          {:stop, reason, %{state | frame: new_frame}}
      end
    else
      {:noreply, state}
    end
  end

  # Session serialization

  @doc false
  @spec to_serializable(t()) :: map()
  def to_serializable(%{session_id: session_id, server_module: module} = state) do
    frame = maybe_serialize_assigns(module, state.frame)

    %{
      id: session_id,
      protocol_version: state.protocol_version,
      protocol_module: serialize_module(state.protocol_module),
      initialized: state.initialized,
      client_info: state.client_info,
      client_capabilities: state.client_capabilities,
      init_meta: state.init_meta,
      log_level: state.log_level,
      pending_requests: state.pending_requests,
      frame: Frame.to_saved(frame)
    }
  end

  defp maybe_serialize_assigns(module, frame) do
    if Anubis.exported?(module, :serialize_assigns, 1),
      do: %{frame | assigns: module.serialize_assigns(frame.assigns)},
      else: frame
  end

  @doc false
  @spec from_serializable(map()) :: map()
  def from_serializable(map) when is_map(map) do
    %{
      session_id: map["id"],
      protocol_version: map["protocol_version"],
      protocol_module: deserialize_module(map["protocol_module"]),
      initialized: map["initialized"],
      client_info: map["client_info"],
      client_capabilities: map["client_capabilities"],
      init_meta: map["init_meta"] || %{},
      log_level: map["log_level"],
      pending_requests: map["pending_requests"] || %{},
      frame: Frame.from_saved(map["frame"] || %{})
    }
  end

  defp serialize_module(nil), do: nil
  defp serialize_module(mod) when is_atom(mod), do: Atom.to_string(mod)

  defp deserialize_module(nil), do: nil

  defp deserialize_module(mod) when is_binary(mod) do
    String.to_existing_atom(mod)
  rescue
    ArgumentError -> nil
  end

  # Session persistence

  defp maybe_call_init(module, client_info, frame) do
    if Anubis.exported?(module, :init, 2) do
      module.init(client_info, frame)
    else
      {:ok, frame}
    end
  rescue
    e -> {:error, e}
  end

  defp maybe_call_session_expired(module, session_id, frame) do
    if Anubis.exported?(module, :handle_session_expired, 2) do
      module.handle_session_expired(session_id, frame)
    else
      :default
    end
  rescue
    e -> {:error, e}
  end

  defp maybe_restore_from_store(session_id) do
    case Anubis.get_session_store_adapter() do
      nil ->
        {nil, nil, %{}}

      store ->
        case store.load(session_id, []) do
          {:ok, saved} -> parse_restored(saved)
          _ -> {nil, nil, %{}}
        end
    end
  end

  defp parse_restored(saved) do
    client_info = saved["client_info"] || saved[:client_info]
    frame = Frame.from_saved(saved["frame"] || saved[:frame] || %{})
    init_meta = saved["init_meta"] || saved[:init_meta] || %{}
    {client_info, frame, init_meta}
  end

  defp fallback_to_init(module, auto_state, frame, protocol_version, state) do
    case maybe_call_init(module, auto_state.client_info, frame) do
      {:ok, frame} -> do_complete_auto_init(auto_state, frame, protocol_version)
      {:error, reason} -> {:reply, {:error, Error.wrap_reason(reason)}, state}
    end
  end

  defp do_complete_auto_init(auto_state, frame, protocol_version) do
    Logging.server_event("session_auto_initialized", %{
      session_id: auto_state.session_id,
      protocol_version: protocol_version
    })

    maybe_persist_session(%{auto_state | frame: frame})
    {:reply, :ok, %{auto_state | frame: frame}}
  end

  defp maybe_schedule_store_ttl_refresh do
    if Anubis.get_session_store_adapter() do
      interval = div(Anubis.get_session_store_ttl(), 2)
      Process.send_after(self(), :refresh_store_ttl, interval)
    end
  end

  defp refresh_store_ttl(%{initialized: false}), do: :ok

  defp refresh_store_ttl(%{session_id: session_id} = state) do
    if store = Anubis.get_session_store_adapter() do
      case store.update_ttl(session_id, Anubis.get_session_store_ttl(), []) do
        :ok ->
          :ok

        {:error, :not_found} ->
          maybe_persist_session(state)

        {:error, reason} ->
          Logging.log(
            :warning,
            "Failed to refresh store TTL for session #{inspect(session_id)}",
            session_id: session_id,
            error: reason
          )

          :ok
      end
    end
  end

  defp maybe_persist_session(%{session_id: session_id} = state) do
    if store = Anubis.get_session_store_adapter() do
      Logging.log(:debug, "Persisting session #{inspect(session_id)} to store", [])

      state_map = to_serializable(state)

      case store.save(session_id, state_map, []) do
        :ok ->
          Logging.log(:debug, "Successfully persisted session #{inspect(session_id)}", [])

        {:error, reason} ->
          Telemetry.execute(
            Telemetry.event_server_error(),
            %{system_time: System.system_time()},
            %{session_id: session_id, error: reason, operation: :persist_session}
          )

          Logging.log(
            :warning,
            "Failed to persist session #{inspect(session_id)}",
            session_id: session_id,
            error: reason
          )

          :ok
      end
    end
  end

  # Format helpers

  defp format_state(state) do
    pending = format_pending_requests(state.server_requests)

    state
    |> Map.take([
      :session_id,
      :server_module,
      :initialized,
      :protocol_version,
      :capabilities,
      :frame
    ])
    |> Map.merge(%{
      transport: state.transport[:layer],
      pending_server_requests: pending
    })
  end

  defp format_pending_requests(requests) do
    Enum.map(requests, fn {id, req} ->
      %{id: id, method: req[:method]}
    end)
  end

  defp maybe_put_instructions(result, nil), do: result

  defp maybe_put_instructions(result, instructions) when is_binary(instructions),
    do: Map.put(result, "instructions", instructions)

  # Tasks (MCP spec 2025-11-25)

  defp build_task_store(nil), do: nil

  defp build_task_store(opts) when is_list(opts) do
    %{adapter: Keyword.fetch!(opts, :adapter), name: Keyword.fetch!(opts, :name)}
  end

  defp tasks_supported_for_tools_call?(state) do
    case state.capabilities do
      %{"tasks" => %{"requests" => %{"tools" => %{"call" => _}}}} -> not is_nil(state.task_store)
      _ -> false
    end
  end

  defp tasks_cancel_supported?(state) do
    case state.capabilities do
      %{"tasks" => %{"cancel" => _}} -> not is_nil(state.task_store)
      _ -> false
    end
  end

  defp clamp_task_ttl(nil), do: @default_task_ttl

  defp clamp_task_ttl(ttl) when is_integer(ttl) do
    ttl |> max(@min_task_ttl) |> min(@max_task_ttl)
  end

  defp lookup_tool(server_module, frame, tool_name) do
    server_module
    |> Handlers.get_server_tools(frame)
    |> Enum.find(&(&1.name == tool_name))
  end

  defp task_augmented_tools_call?(%{"method" => "tools/call", "params" => %{"task" => _}}), do: true
  defp task_augmented_tools_call?(_), do: false

  defp dispatch_tasks_request(%{"method" => "tasks/get", "id" => req_id} = request, _ctx, _from, state) do
    if is_nil(state.task_store) do
      tasks_unsupported_reply(req_id, "tasks/get", state)
    else
      frame = prepare_frame(state)

      {result, frame} =
        request
        |> TasksHandler.handle_get(frame, %{
          task_store_adapter: state.task_store.adapter,
          task_store_name: state.task_store.name,
          session_id: state.session_id
        })
        |> reply_to_handler_result(req_id)

      {:reply, result, %{state | frame: frame}}
    end
  end

  defp dispatch_tasks_request(
         %{"method" => "tasks/result", "id" => req_id, "params" => %{"taskId" => task_id}},
         _ctx,
         from,
         state
       ) do
    if is_nil(state.task_store) do
      tasks_unsupported_reply(req_id, "tasks/result", state)
    else
      handle_tasks_result(task_id, req_id, from, state)
    end
  end

  defp dispatch_tasks_request(%{"method" => "tasks/cancel", "id" => req_id} = request, _ctx, _from, state) do
    if tasks_cancel_supported?(state) do
      handle_tasks_cancel(request, state)
    else
      tasks_unsupported_reply(req_id, "tasks/cancel", state)
    end
  end

  defp dispatch_tasks_request(%{"method" => "tasks/list", "id" => req_id}, _ctx, _from, state) do
    frame = prepare_frame(state)
    {:error, error, frame} = TasksHandler.handle_list_unsupported(frame)
    {:reply, {:ok, encode_reply(Error.build_json_rpc(error, req_id))}, %{state | frame: frame}}
  end

  defp tasks_unsupported_reply(req_id, method, state) do
    error = Error.protocol(:method_not_found, %{message: "#{method} not supported by this server"})
    {:reply, {:ok, encode_reply(Error.build_json_rpc(error, req_id))}, state}
  end

  defp handle_tasks_result(task_id, req_id, from, state) do
    case task_store_get(state, task_id) do
      {:ok, %McpTask{} = task} ->
        if McpTask.terminal?(task) do
          payload = build_tasks_result_payload(task, req_id)
          {:reply, {:ok, encode_reply(payload)}, state}
        else
          {:noreply, register_result_waiter(state, task_id, from, req_id)}
        end

      {:error, :not_found} ->
        error = TasksHandler.task_not_found(task_id)
        {:reply, {:ok, encode_reply(Error.build_json_rpc(error, req_id))}, state}
    end
  end

  defp handle_tasks_cancel(%{"id" => req_id} = request, state) do
    frame = prepare_frame(state)
    %{"params" => %{"taskId" => task_id}} = request

    case cancel_task(state, task_id) do
      {:ok, %McpTask{} = task, new_state} ->
        payload = McpTask.to_protocol(task)
        {:reply, {:ok, encode_reply(Message.build_response(payload, req_id))}, %{new_state | frame: frame}}

      {:error, :not_found} ->
        error = TasksHandler.task_not_found(task_id)
        {:reply, {:ok, encode_reply(Error.build_json_rpc(error, req_id))}, %{state | frame: frame}}

      {:error, {:already_terminal, status}} ->
        error =
          Error.protocol(:invalid_params, %{
            message: "Cannot cancel task: already in terminal status '#{status}'"
          })

        {:reply, {:ok, encode_reply(Error.build_json_rpc(error, req_id))}, %{state | frame: frame}}
    end
  end

  defp reply_to_handler_result({:reply, payload, frame}, req_id) do
    {{:ok, encode_reply(Message.build_response(payload, req_id))}, frame}
  end

  defp reply_to_handler_result({:error, %Error{} = error, frame}, req_id) do
    {{:ok, encode_reply(Error.build_json_rpc(error, req_id))}, frame}
  end

  defp register_result_waiter(state, task_id, from, req_id) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, %{waiters: waiters} = runtime} ->
        %{state | tasks: Map.put(state.tasks, task_id, %{runtime | waiters: [{from, req_id} | waiters]})}

      :error ->
        error = TasksHandler.task_not_found(task_id)
        GenServer.reply(from, {:ok, encode_reply(Error.build_json_rpc(error, req_id))})
        state
    end
  end

  defp build_tasks_result_payload(%McpTask{result: result, error: nil} = task, req_id) when not is_nil(result) do
    Message.build_response(inject_related_task(result, task.id), req_id)
  end

  defp build_tasks_result_payload(%McpTask{error: %Error{} = error, status: :failed}, req_id) do
    Error.build_json_rpc(error, req_id)
  end

  defp build_tasks_result_payload(%McpTask{error: %Error{} = error, status: :cancelled}, req_id) do
    Error.build_json_rpc(error, req_id)
  end

  defp build_tasks_result_payload(%McpTask{status: :cancelled} = task, req_id) do
    error =
      Error.execution("Task cancelled", %{taskId: task.id})

    Error.build_json_rpc(error, req_id)
  end

  defp build_tasks_result_payload(%McpTask{status: :failed} = task, req_id) do
    error =
      Error.execution("Task failed", %{taskId: task.id})

    Error.build_json_rpc(error, req_id)
  end

  defp build_tasks_result_payload(%McpTask{} = task, req_id) do
    Message.build_response(inject_related_task(%{}, task.id), req_id)
  end

  defp inject_related_task(%{} = result, task_id) do
    meta = Map.get(result, "_meta", %{})
    related = Map.put(meta, "io.modelcontextprotocol/related-task", %{"taskId" => task_id})
    Map.put(result, "_meta", related)
  end

  defp task_store_get(%{task_store: nil}, _id), do: {:error, :not_found}

  defp task_store_get(%{task_store: %{adapter: adapter, name: name}, session_id: session_id}, task_id) do
    adapter.get(name, session_id, task_id)
  end

  defp task_store_put(%{task_store: %{adapter: adapter, name: name}, session_id: session_id} = state, %McpTask{} = task) do
    :ok = adapter.put(name, session_id, task)
    state
  end

  defp task_store_update(%{task_store: %{adapter: adapter, name: name}, session_id: session_id}, task_id, fun) do
    adapter.update(name, session_id, task_id, fun)
  end

  defp task_store_delete(%{task_store: %{adapter: adapter, name: name}, session_id: session_id}, task_id) do
    adapter.delete(name, session_id, task_id)
  end

  defp create_task_for_tools_call(%{"id" => req_id, "params" => params} = request, _ctx, from, state) do
    if tasks_supported_for_tools_call?(state) do
      do_create_task_for_tools_call(request, params, req_id, from, state)
    else
      error = Error.protocol(:method_not_found, %{message: "Server does not support task-augmented tools/call"})
      {:reply, {:ok, encode_reply(Error.build_json_rpc(error, req_id))}, state}
    end
  end

  defp do_create_task_for_tools_call(request, params, req_id, _from, state) do
    tool_name = params["name"]
    frame = prepare_frame(state)
    tool = lookup_tool(state.server_module, frame, tool_name)

    cond do
      is_nil(tool) ->
        error = Error.protocol(:invalid_params, %{message: "Tool not found: #{tool_name}"})
        {:reply, {:ok, encode_reply(Error.build_json_rpc(error, req_id))}, state}

      tool.task_support == :forbidden ->
        error =
          Error.protocol(:method_not_found, %{
            message: "Tool does not support task augmentation (execution.taskSupport == \"forbidden\")"
          })

        {:reply, {:ok, encode_reply(Error.build_json_rpc(error, req_id))}, state}

      true ->
        spawn_task_worker(request, tool, params, req_id, state)
    end
  end

  defp spawn_task_worker(request, _tool, params, req_id, state) do
    requested_ttl = get_in(params, ["task", "ttl"])
    ttl = clamp_task_ttl(requested_ttl)

    task =
      McpTask.new(
        session_id: state.session_id,
        method: "tools/call",
        request_id: req_id,
        ttl: ttl,
        poll_interval: @default_task_poll_interval,
        original_params: Map.delete(params, "task")
      )

    state = task_store_put(state, task)

    frame = state |> prepare_frame() |> Map.put(:task_id, task.id)

    request = %{request | "params" => Map.delete(params, "task")}

    server_module = state.server_module

    worker =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Handlers.handle(request, server_module, frame)
      end)

    ttl_timer = Process.send_after(self(), {:task_expired, task.id}, ttl)

    runtime = %{
      worker_ref: worker.ref,
      worker_pid: worker.pid,
      ttl_timer: ttl_timer,
      waiters: [],
      request_id: req_id
    }

    state = %{
      state
      | tasks: Map.put(state.tasks, task.id, runtime),
        task_refs: Map.put(state.task_refs, worker.ref, task.id)
    }

    create_task_result = McpTask.to_create_result(task)
    response = Message.build_response(inject_related_task(create_task_result, task.id), req_id)

    {:reply, {:ok, encode_reply(response)}, state}
  end

  defp handle_task_worker_completion(task_id, callback_result, state) do
    {status, attrs} = derive_finalize_attrs(callback_result)
    {_task, state} = finalize_task_runtime(task_id, status, attrs, state)
    {:noreply, state}
  end

  defp handle_task_worker_down(task_id, reason, state) do
    error = Error.protocol(:internal_error, %{message: "Task worker crashed", reason: inspect(reason)})
    {_task, state} = finalize_task_runtime(task_id, :failed, [error: error, status_message: error.message], state)
    {:noreply, state}
  end

  defp handle_task_expired(task_id, state) do
    case Map.pop(state.tasks, task_id) do
      {nil, _} ->
        # No live runtime — task was already finalized (the timer fired late
        # or the message raced with worker completion). Don't blow away a
        # terminal record from the store on a stale expiry.
        {:noreply, state}

      {%{worker_pid: pid, worker_ref: ref, waiters: waiters}, tasks} ->
        if pid && Process.alive?(pid) do
          _ = Task.Supervisor.terminate_child(state.task_supervisor, pid)
        end

        if ref, do: Process.demonitor(ref, [:flush])

        release_waiters(%{waiters: waiters}, TasksHandler.task_expired(task_id))

        task_store_delete(state, task_id)

        state = %{
          state
          | tasks: tasks,
            task_refs: if(ref, do: Map.delete(state.task_refs, ref), else: state.task_refs)
        }

        {:noreply, state}
    end
  end

  defp finalize_task_runtime(task_id, status, attrs, state) do
    {runtime, state} = pop_task_runtime(state, task_id)

    case task_store_update(state, task_id, fn task -> McpTask.transition(task, status, attrs) end) do
      {:ok, %McpTask{} = task} ->
        release_waiters(runtime, task)
        {task, state}

      {:error, :not_found} ->
        release_waiters(runtime, TasksHandler.task_not_found(task_id))
        {nil, state}
    end
  end

  defp derive_finalize_attrs({:reply, payload, _frame}) when is_map(payload) do
    {status, attrs} = classify_tool_call_payload(payload)
    {status, attrs}
  end

  defp derive_finalize_attrs({:noreply, _frame}) do
    {:completed, [result: %{"content" => [], "isError" => false}, status_message: nil]}
  end

  defp derive_finalize_attrs({:error, %Error{} = error, _frame}) do
    {:failed, [error: error, status_message: error.message]}
  end

  defp derive_finalize_attrs(other) do
    err = Error.protocol(:internal_error, %{message: "Invalid task worker return", returned: inspect(other)})
    {:failed, [error: err, status_message: err.message]}
  end

  defp classify_tool_call_payload(%{"isError" => true} = payload) do
    {:failed, [result: payload, status_message: "Tool returned isError: true"]}
  end

  defp classify_tool_call_payload(payload) do
    {:completed, [result: payload, status_message: nil]}
  end

  defp pop_task_runtime(state, task_id) do
    case Map.pop(state.tasks, task_id) do
      {nil, tasks} ->
        {nil, %{state | tasks: tasks}}

      {%{worker_ref: ref} = runtime, tasks} ->
        if ref, do: Process.demonitor(ref, [:flush])
        if runtime.ttl_timer, do: cancel_ttl_timer(runtime.ttl_timer, task_id)
        task_refs = if ref, do: Map.delete(state.task_refs, ref), else: state.task_refs
        {runtime, %{state | tasks: tasks, task_refs: task_refs}}
    end
  end

  # `Process.cancel_timer/1` does not flush an already-delivered message, so
  # if the timer fires in the same scheduling slice as worker completion the
  # `{:task_expired, ^task_id}` message would still be in the mailbox and could
  # later wipe the terminal task from the store.
  defp cancel_ttl_timer(timer_ref, task_id) do
    Process.cancel_timer(timer_ref)

    receive do
      {:task_expired, ^task_id} -> :ok
    after
      0 -> :ok
    end
  end

  defp release_waiters(nil, _result), do: :ok

  defp release_waiters(%{waiters: waiters}, %McpTask{} = task) do
    Enum.each(waiters, fn {from, req_id} ->
      reply = build_tasks_result_payload(task, req_id)
      GenServer.reply(from, {:ok, encode_reply(reply)})
    end)
  end

  defp release_waiters(%{waiters: waiters}, %Error{} = error) do
    Enum.each(waiters, fn {from, req_id} ->
      GenServer.reply(from, {:ok, encode_reply(Error.build_json_rpc(error, req_id))})
    end)
  end

  # Cancel a task on demand. Terminates the worker if alive, flips status to
  # :cancelled, releases waiters with a cancellation error, and returns the
  # final task projection alongside the new state.
  defp cancel_task(state, task_id) do
    case task_store_get(state, task_id) do
      {:ok, %McpTask{} = task} ->
        if McpTask.terminal?(task) do
          {:error, {:already_terminal, task.status}}
        else
          do_cancel_task(state, task)
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp do_cancel_task(state, %McpTask{id: task_id}) do
    {runtime, state} = pop_task_runtime(state, task_id)

    if runtime && runtime.worker_pid && Process.alive?(runtime.worker_pid) do
      _ = Task.Supervisor.terminate_child(state.task_supervisor, runtime.worker_pid)
    end

    error = Error.execution("The task was cancelled by request.", %{taskId: task_id})

    case task_store_update(state, task_id, fn task ->
           McpTask.transition(task, :cancelled, error: error, status_message: "The task was cancelled by request.")
         end) do
      {:ok, cancelled} ->
        release_waiters(runtime, cancelled)
        {:ok, cancelled, state}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp task_id_for_ref(state, ref), do: Map.get(state.task_refs, ref)

  defp emit_task_status_notification(state, task_id) do
    case task_store_get(state, task_id) do
      {:ok, %McpTask{} = task} ->
        params = McpTask.to_protocol(task)

        with {:ok, notification} <- encode_notification("notifications/tasks/status", params) do
          send_to_transport(state.transport, notification, transport_opts(state))
        end

      _ ->
        :ok
    end
  end
end
