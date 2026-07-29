defmodule Anubis.Server.Session.Scheduler do
  @moduledoc """
  Request scheduling engine for a session.

  Owns the single in-flight request slot, the FIFO request queue, callbacks
  deferred while a request is in flight, and cancellation of in-flight or
  queued requests. At most one request executes at a time per session: while
  one runs, competing requests queue and competing casts/infos are deferred,
  then drained in order once the in-flight request completes.

  State fields (`in_flight`, `request_queue`, `deferred_callbacks`,
  `pending_requests`) live in the Session's state map; this module
  transforms them and performs the side effects (task spawn, monitors,
  caller replies, logging, telemetry) at the edges. `Anubis.Server.Session`
  delegates to this module and supplies callbacks to prepare frames and to
  apply drained deferred items back into its own dispatch paths.
  """

  use Anubis.Logging

  alias Anubis.MCP.Error
  alias Anubis.MCP.Message
  alias Anubis.Server.Frame
  alias Anubis.Telemetry

  @type in_flight :: %{
          ref: reference(),
          pid: pid(),
          request_id: String.t(),
          from: GenServer.from(),
          started_at: integer(),
          method: String.t()
        }

  @type queued_request :: {map(), map(), GenServer.from()}
  @type deferred_callback :: {:cast | :info, term()}
  @type state :: map()
  @type frame_fn :: (state(), map() | nil -> Frame.t())

  @type apply_deferred_fn ::
          (deferred_callback(), state() ->
             {:noreply, state()} | {:noreply, state(), term()} | {:stop, term(), state()})

  @type callbacks :: %{frame: frame_fn(), apply_deferred: apply_deferred_fn()}

  @doc """
  Dispatches the request immediately when no request is in flight, otherwise
  appends it to the request queue.
  """
  @spec enqueue_or_dispatch(map(), map(), GenServer.from(), state(), callbacks()) :: {:noreply, state()}
  def enqueue_or_dispatch(request, ctx, from, %{in_flight: nil} = state, callbacks) do
    {:noreply, dispatch_request(request, ctx, from, state, callbacks.frame)}
  end

  def enqueue_or_dispatch(request, ctx, from, state, _callbacks) do
    {:noreply, %{state | request_queue: :queue.in({request, ctx, from}, state.request_queue)}}
  end

  @doc """
  Defers a cast or info message to be applied once the in-flight request
  completes.
  """
  @spec defer(state(), deferred_callback()) :: state()
  def defer(state, item) do
    %{state | deferred_callbacks: :queue.in(item, state.deferred_callbacks)}
  end

  @doc """
  Handles completion of the in-flight request task: decodes the handler
  result, replies to the caller, drains deferred callbacks, and dispatches
  the next queued request.
  """
  @spec handle_completion(reference(), term(), state(), callbacks()) ::
          {:noreply, state()} | {:stop, term(), state()}
  def handle_completion(ref, callback_result, %{in_flight: %{ref: ref} = inflight} = state, callbacks) do
    Process.demonitor(ref, [:flush])
    {reply, state} = decode_task_result(callback_result, inflight, state)
    state = complete_request(%{state | in_flight: nil}, inflight.request_id)
    GenServer.reply(inflight.from, reply)

    finalize_after_task(state, callbacks)
  end

  @doc """
  Handles a crash of the in-flight request task, replying to the caller with
  an internal error before finalizing.
  """
  @spec handle_down(term(), state(), callbacks()) :: {:noreply, state()} | {:stop, term(), state()}
  def handle_down(reason, %{in_flight: inflight} = state, callbacks) do
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

    finalize_after_task(state, callbacks)
  end

  @doc """
  Handles a `notifications/cancelled` notification, cancelling either the
  in-flight request or any queued entries matching the request ID.
  """
  @spec cancel(map(), state(), callbacks()) :: {:noreply, state()} | {:stop, term(), state()}
  def cancel(notification, state, callbacks) do
    params = notification["params"] || %{}
    request_id = params["requestId"]
    reason = Map.get(params, "reason", "cancelled")

    cond do
      in_flight?(state, request_id) ->
        cancel_in_flight(state, request_id, reason, callbacks)

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

  @doc """
  Replies to the in-flight and queued callers with the given error during
  session termination, terminating the in-flight worker task.
  """
  @spec reply_pending(state(), Error.t()) :: :ok
  def reply_pending(%{in_flight: in_flight, request_queue: q, task_supervisor: task_supervisor}, error) do
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
  end

  defp dispatch_request(%{"id" => request_id, "method" => method} = request, transport_context, from, state, frame_fn) do
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

    frame = frame_fn.(state, transport_context)
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

  defp do_handle_request(module, %{"method" => "tools/call"} = request, frame, _method) do
    tool_name = get_in(request, ["params", "name"])

    :telemetry.span(
      [:anubis_mcp | Telemetry.event_server_tool_call()],
      %{tool: tool_name},
      fn ->
        result = module.handle_request(request, frame)
        {result, %{tool: tool_name, is_error: tool_call_error?(result)}}
      end
    )
  end

  defp do_handle_request(module, request, frame, _method) do
    module.handle_request(request, frame)
  end

  defp tool_call_error?({:error, _reason, _frame}), do: true
  defp tool_call_error?({:reply, %{"isError" => true}, _frame}), do: true
  defp tool_call_error?(_result), do: false

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

  defp drain_deferred_callbacks(%{deferred_callbacks: q} = state, apply_fn) do
    state = %{state | deferred_callbacks: :queue.new()}

    Enum.reduce_while(:queue.to_list(q), state, fn item, acc ->
      case apply_fn.(item, acc) do
        {:noreply, new_state} -> {:cont, new_state}
        {:noreply, new_state, _cont} -> {:cont, new_state}
        {:stop, _reason, _new_state} = stop -> {:halt, stop}
      end
    end)
  end

  defp finalize_after_task(state, callbacks) do
    case drain_deferred_callbacks(state, callbacks.apply_deferred) do
      {:stop, _reason, _new_state} = stop -> stop
      new_state -> new_state |> dispatch_next_queued(callbacks.frame) |> noreply()
    end
  end

  defp dispatch_next_queued(%{request_queue: q} = state, frame_fn) do
    case :queue.out(q) do
      {:empty, _} ->
        state

      {{:value, {request, ctx, from}}, rest} ->
        dispatch_request(request, ctx, from, %{state | request_queue: rest}, frame_fn)
    end
  end

  defp noreply(state), do: {:noreply, state}

  defp in_flight?(%{in_flight: %{request_id: rid}}, rid), do: true
  defp in_flight?(_, _), do: false

  defp queued?(%{request_queue: q}, rid) do
    Enum.any?(:queue.to_list(q), fn {%{"id" => id}, _ctx, _from} -> id == rid end)
  end

  defp cancel_in_flight(%{in_flight: inflight} = state, request_id, reason, callbacks) do
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
    finalize_after_task(state, callbacks)
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

  defp flush_task_reply(ref) do
    receive do
      {^ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp encode_reply(message) when is_map(message) do
    JSON.encode!(message)
  end
end
