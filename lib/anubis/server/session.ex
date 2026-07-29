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

  alias Anubis.MCP.Error
  alias Anubis.MCP.Message
  alias Anubis.Server
  alias Anubis.Server.Context
  alias Anubis.Server.Frame
  alias Anubis.Server.Session.Scheduler
  alias Anubis.Server.Session.ServerRequests
  alias Anubis.Server.Session.Tasks
  alias Anubis.Telemetry

  require Message
  require Server

  @default_session_idle_timeout to_timeout(minute: 30)

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
          task_store: Tasks.store() | nil,
          tasks: %{String.t() => Tasks.task_runtime()},
          task_refs: %{reference() => String.t()},
          in_flight: Scheduler.in_flight() | nil,
          request_queue: :queue.queue(Scheduler.queued_request()),
          deferred_callbacks: :queue.queue(Scheduler.deferred_callback())
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
      task_store: Tasks.build_store(opts[:task_store]),
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
      {:noreply, Scheduler.defer(state, {:cast, msg})}
    end
  end

  def handle_cast({:mcp_notification, decoded, _ctx} = msg, state) when is_map(decoded) do
    process_mcp_notification(msg, state)
  end

  # Server-initiated request responses (sampling/roots)

  def handle_cast({:mcp_response, decoded, _ctx} = msg, %{in_flight: f} = state) when not is_nil(f) and is_map(decoded) do
    {:noreply, Scheduler.defer(state, {:cast, msg})}
  end

  def handle_cast({:mcp_response, decoded, _context}, state) when is_map(decoded) do
    process_mcp_response(decoded, state)
  end

  def handle_cast(request, %{in_flight: f} = state) when not is_nil(f) do
    {:noreply, Scheduler.defer(state, {:cast, request})}
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
      Message.is_response(decoded) and ServerRequests.server_request?(decoded["id"], state) ->
        ServerRequests.handle_response(decoded, state, &prepare_frame/1)

      Message.is_error(decoded) and ServerRequests.server_request?(decoded["id"], state) ->
        ServerRequests.handle_error(decoded, state)

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

  defp scheduler_callbacks do
    %{frame: &prepare_frame/2, apply_deferred: &apply_deferred/2}
  end

  defp apply_deferred({:cast, {:mcp_notification, _, _} = msg}, state), do: process_mcp_notification(msg, state)
  defp apply_deferred({:cast, {:mcp_response, decoded, _ctx}}, state), do: process_mcp_response(decoded, state)
  defp apply_deferred({:cast, msg}, state), do: process_user_cast(msg, state)
  defp apply_deferred({:info, msg}, state), do: process_user_info(msg, state)

  # Handle info messages

  @impl GenServer
  def handle_info({:send_notification, method, params}, state) do
    with {:ok, notification} <- ServerRequests.encode_notification(method, params),
         :ok <- ServerRequests.send_to_transport(state.transport, notification, ServerRequests.transport_opts(state)) do
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
    ServerRequests.send_request(:sampling, params, timeout, state)
  end

  def handle_info({:sampling_request_timeout, request_id}, state) do
    ServerRequests.handle_timeout(:sampling, request_id, state)
  end

  def handle_info({:send_roots_request, timeout}, state) do
    ServerRequests.send_request(:roots, %{}, timeout, state)
  end

  def handle_info({:roots_request_timeout, request_id}, state) do
    ServerRequests.handle_timeout(:roots, request_id, state)
  end

  def handle_info({:send_elicitation_request, params, requested_schema, timeout}, state) do
    ServerRequests.send_request(:elicitation, params, timeout, state, %{requested_schema: requested_schema})
  end

  def handle_info({:elicitation_request_timeout, request_id}, state) do
    ServerRequests.handle_timeout(:elicitation, request_id, state)
  end

  def handle_info({ref, callback_result}, %{in_flight: %{ref: ref}} = state) do
    Scheduler.handle_completion(ref, callback_result, state, scheduler_callbacks())
  end

  def handle_info({ref, callback_result}, state) when is_reference(ref) do
    case Tasks.task_id_for_ref(state, ref) do
      nil ->
        {:noreply, state}

      task_id ->
        Process.demonitor(ref, [:flush])
        Tasks.handle_worker_completion(task_id, callback_result, state)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    cond do
      task_id = Tasks.task_id_for_ref(state, ref) ->
        Tasks.handle_worker_down(task_id, reason, state)

      state.in_flight && state.in_flight.ref == ref ->
        Scheduler.handle_down(reason, state, scheduler_callbacks())

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:task_expired, task_id}, state) do
    Tasks.handle_expired(task_id, state)
  end

  def handle_info({:send_task_status, task_id}, state) do
    _ = Tasks.emit_status_notification(state, task_id)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(event, %{in_flight: f} = state) when not is_nil(f) do
    {:noreply, Scheduler.defer(state, {:info, event})}
  end

  def handle_info(event, state) do
    process_user_info(event, state)
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

  defp reply_to_pending_callers(state, reason) do
    error =
      Error.protocol(:internal_error, %{
        message: "Session terminating",
        reason: inspect(reason)
      })

    Scheduler.reply_pending(state, error)
    Tasks.terminate_all(state, error)
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
      Message.is_response(decoded) and ServerRequests.server_request?(decoded["id"], state) ->
        {:noreply, new_state} = ServerRequests.handle_response(decoded, state, &prepare_frame/1)
        {:reply, {:ok, nil}, new_state}

      Message.is_error(decoded) and ServerRequests.server_request?(decoded["id"], state) ->
        {:noreply, new_state} = ServerRequests.handle_error(decoded, state)
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
      %{method: "initialize", status: :success, client_info: client_info}
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
    Tasks.dispatch_request(request, ctx, from, state, &prepare_frame/1)
  end

  defp handle_request(%{"method" => "tools/call"} = request, ctx, from, state) do
    if Tasks.augmented_tools_call?(request) do
      Tasks.create_for_tools_call(request, ctx, from, state, &prepare_frame/1)
    else
      Scheduler.enqueue_or_dispatch(request, ctx, from, state, scheduler_callbacks())
    end
  end

  defp handle_request(%{"id" => _, "method" => _} = request, transport_context, from, state) do
    Scheduler.enqueue_or_dispatch(request, transport_context, from, state, scheduler_callbacks())
  end

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
    Scheduler.cancel(notification, state, scheduler_callbacks())
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

  # Session serialization

  # Bump when the serialized shape changes; from_serializable/1 must keep
  # reading the previous format for one major cycle (see #252).
  @serialization_version 1

  @doc false
  @spec to_serializable(t()) :: map()
  def to_serializable(%{session_id: session_id, server_module: module} = state) do
    frame = maybe_serialize_assigns(module, state.frame)

    %{
      v: @serialization_version,
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
    # Legacy payloads (no "v" field) predate versioning and share the v1
    # shape; accept both for one major cycle, then drop the legacy path.
    _version = map["v"] || :legacy

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
end
