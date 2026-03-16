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
  alias Anubis.MCP.ID
  alias Anubis.MCP.Message
  alias Anubis.Server
  alias Anubis.Server.Context
  alias Anubis.Server.Frame
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
          log_level: String.t() | nil,
          frame: Frame.t(),
          server_info: map(),
          capabilities: map(),
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
          task_supervisor: GenServer.name()
        }

  defschema(:parse_options, [
    {:session_id, {:required, :string}},
    {:server_module, {:required, :atom}},
    {:name, {:required, {:custom, &Anubis.genserver_name/1}}},
    {:transport, {:required, {:custom, &Anubis.server_transport/1}}},
    {:registry, {:atom, {:default, Anubis.Server.Registry}}},
    {:session_idle_timeout, {{:integer, {:gte, 1}}, {:default, @default_session_idle_timeout}}},
    {:timeout, {:integer, {:default, to_timeout(second: 30)}}},
    {:task_supervisor, {:required, {:custom, &Anubis.genserver_name/1}}}
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

  # Lifecycle

  @impl GenServer
  def init(opts) do
    module = opts.server_module
    server_info = module.server_info()
    capabilities = module.server_capabilities()
    protocol_versions = module.supported_protocol_versions()

    state = %{
      session_id: opts.session_id,
      server_module: module,
      protocol_version: nil,
      protocol_module: nil,
      initialized: false,
      client_info: nil,
      client_capabilities: nil,
      log_level: nil,
      frame: Frame.new(),
      server_info: server_info,
      capabilities: capabilities,
      supported_versions: protocol_versions,
      transport: Map.new(opts.transport),
      registry: opts.registry,
      session_idle_timeout: opts.session_idle_timeout,
      expiry_timer: nil,
      pending_requests: %{},
      server_requests: %{},
      timeout: opts.timeout,
      task_supervisor: opts.task_supervisor
    }

    state = schedule_session_expiry(state)

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
  def handle_call({:mcp_request, decoded, transport_context}, _from, state) when is_map(decoded) do
    state = merge_transport_assigns(state, transport_context)
    state = reset_session_expiry(state)

    handle_single_request(decoded, transport_context, state)
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
  def handle_cast({:mcp_notification, decoded, transport_context}, state) when is_map(decoded) do
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

  # Server-initiated request responses (sampling/roots)

  def handle_cast({:mcp_response, decoded, _context}, state) when is_map(decoded) do
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

  def handle_cast(request, %{server_module: module} = state) do
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

  # Handle info messages

  @impl GenServer
  def handle_info({:send_notification, method, params}, state) do
    with {:ok, notification} <- encode_notification(method, params),
         :ok <- send_to_transport(state.transport, notification, timeout: state.timeout) do
      {:noreply, state}
    else
      {:error, err} ->
        Logging.server_event("failed_send_notification", %{method: method, error: err}, level: :error)

        {:noreply, state}
    end
  end

  def handle_info(:session_expired, state) do
    Logging.server_event("session_expired", %{session_id: state.session_id})
    {:stop, {:shutdown, :session_expired}, state}
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

  def handle_info(event, %{server_module: module} = state) do
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

  @impl GenServer
  def terminate(reason, %{server_module: module, server_info: server_info} = state) do
    cancel_session_expiry(state)

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

  defp handle_single_request(decoded, transport_context, state) do
    cond do
      Message.is_response(decoded) and server_request?(decoded["id"], state) ->
        handle_server_request_response(decoded, state)

      Message.is_error(decoded) and server_request?(decoded["id"], state) ->
        handle_server_request_error(decoded, state)

      Message.is_ping(decoded) ->
        handle_server_ping(decoded, state)

      not is_server_initialized(decoded, state) ->
        handle_server_not_initialized(state)

      Message.is_request(decoded) ->
        handle_request(decoded, transport_context, state)

      true ->
        handle_invalid_request(state)
    end
  end

  defp handle_server_ping(%{"id" => request_id}, state) do
    {:reply, {:ok, encode_reply(Message.build_response(%{}, request_id))}, state}
  end

  defp handle_server_not_initialized(state) do
    error = Error.protocol(:invalid_request, %{message: "Server not initialized"})

    Logging.server_event(
      "request_error",
      %{error: error, reason: "not_initialized"},
      level: :warning
    )

    {:reply, {:ok, encode_reply(Error.build_json_rpc(error))}, state}
  end

  defp handle_invalid_request(state) do
    error =
      Error.protocol(:invalid_request, %{
        message: "Expected request but got different message type"
      })

    {:reply, {:error, error}, state}
  end

  # Initialize handling

  defp handle_request(%{"params" => params} = request, _transport_context, state) when Message.is_initialize(request) do
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
        client_capabilities: client_capabilities
    }

    maybe_persist_session(state)

    result = %{
      "protocolVersion" => protocol_version,
      "serverInfo" => state.server_info,
      "capabilities" => state.capabilities
    }

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

  defp handle_request(%{"id" => request_id, "method" => "logging/setLevel"} = request, _transport_context, state)
       when Server.is_supported_capability(state.capabilities, "logging") do
    level = request["params"]["level"]
    state = %{state | log_level: level}
    {:reply, {:ok, encode_reply(Message.build_response(%{}, request_id))}, state}
  end

  defp handle_request(%{"id" => request_id, "method" => method} = request, transport_context, state) do
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
    server_request(request, %{state | frame: frame})
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
    params = notification["params"] || %{}
    request_id = params["requestId"]
    reason = Map.get(params, "reason", "cancelled")

    case Map.get(state.pending_requests, request_id) do
      nil ->
        Logging.server_event("cancellation_for_unknown_request", %{
          session_id: state.session_id,
          request_id: request_id,
          reason: reason
        })

        {:noreply, state}

      request_info ->
        state = complete_request(state, request_id)

        Logging.server_event("request_cancelled", %{
          session_id: state.session_id,
          request_id: request_id,
          reason: reason,
          method: request_info[:method],
          duration_ms: System.system_time(:millisecond) - request_info[:started_at]
        })

        Telemetry.execute(
          Telemetry.event_server_notification(),
          %{system_time: System.system_time()},
          %{
            method: "cancelled",
            session_id: state.session_id,
            request_id: request_id
          }
        )

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

  # Server request/notification dispatch

  defp server_request(%{"id" => request_id, "method" => method} = request, %{server_module: module} = state) do
    case module.handle_request(request, state.frame) do
      {:reply, response, %Frame{} = frame} ->
        Telemetry.execute(
          Telemetry.event_server_response(),
          %{system_time: System.system_time()},
          %{id: request_id, method: method, status: :success}
        )

        state = complete_request(%{state | frame: frame}, request_id)

        {:reply, {:ok, encode_reply(Message.build_response(response, request_id))}, state}

      {:noreply, %Frame{} = frame} ->
        Telemetry.execute(
          Telemetry.event_server_response(),
          %{system_time: System.system_time()},
          %{id: request_id, method: method, status: :noreply}
        )

        state = complete_request(%{state | frame: frame}, request_id)
        {:reply, {:ok, nil}, state}

      {:error, %Error{} = error, %Frame{} = frame} ->
        Logging.server_event(
          "request_error",
          %{id: request_id, method: method, error: error},
          level: :warning
        )

        Telemetry.execute(
          Telemetry.event_server_error(),
          %{system_time: System.system_time()},
          %{id: request_id, method: method, error: error}
        )

        state = complete_request(%{state | frame: frame}, request_id)

        {:reply, {:ok, encode_reply(Error.build_json_rpc(error, request_id))}, state}
    end
  end

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

    context = %Context{
      session_id: state.session_id,
      client_info: state.client_info,
      headers: headers,
      remote_ip: remote_ip
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
         :ok <- send_to_transport(state.transport, request_data, timeout: state.timeout) do
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
         :ok <- send_to_transport(state.transport, request_data, timeout: state.timeout) do
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
         :ok <- send_to_transport(state.transport, notification, timeout: state.timeout) do
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

  # Session serialization

  @doc false
  @spec to_serializable(t()) :: map()
  def to_serializable(%{session_id: session_id} = state) do
    %{
      id: session_id,
      protocol_version: state.protocol_version,
      protocol_module: serialize_module(state.protocol_module),
      initialized: state.initialized,
      client_info: state.client_info,
      client_capabilities: state.client_capabilities,
      log_level: state.log_level,
      pending_requests: state.pending_requests,
      frame: Frame.to_saved(state.frame)
    }
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

  defp maybe_persist_session(%{session_id: session_id} = state) do
    if store = Anubis.get_session_store_adapter() do
      Logging.log(:debug, "Persisting session #{inspect(session_id)} to store", [])

      state_map = to_serializable(state)

      case store.save(session_id, state_map, []) do
        :ok ->
          Logging.log(:debug, "Successfully persisted session #{inspect(session_id)}", [])

        {:error, reason} ->
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
end
