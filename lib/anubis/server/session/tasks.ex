defmodule Anubis.Server.Session.Tasks do
  @moduledoc """
  Tasks runtime for a session (MCP spec 2025-11-25).

  Owns the lifecycle of task-augmented `tools/call` executions: capability
  checks, task creation and worker spawn, status transitions, cancellation,
  TTL expiry, result storage through the configured `Anubis.Server.TaskStore`
  adapter, and replies to `tasks/result` waiters.

  State fields (`tasks`, `task_refs`, `task_store`) live in the Session's
  state map; this module transforms them and performs the side effects
  (worker spawn, monitors, timers, store calls, waiter replies) at the
  edges. `Anubis.Server.Session` delegates to this module and supplies a
  `frame_fn` to prepare frames lazily.
  """

  alias Anubis.MCP.Error
  alias Anubis.MCP.Message
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers
  alias Anubis.Server.Handlers.Tasks, as: TasksHandler
  alias Anubis.Server.Session.ServerRequests
  alias Anubis.Server.Task, as: McpTask

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

  @type store :: %{adapter: module(), name: term()}
  @type state :: map()
  @type frame_fn :: (state() -> Frame.t())

  @doc """
  Builds the task store configuration from the `:task_store` session option.
  """
  @spec build_store(keyword() | nil) :: store() | nil
  def build_store(nil), do: nil

  def build_store(opts) when is_list(opts) do
    %{adapter: Keyword.fetch!(opts, :adapter), name: Keyword.fetch!(opts, :name)}
  end

  @doc """
  Returns true if the request is a `tools/call` carrying task augmentation
  params.
  """
  @spec augmented_tools_call?(map()) :: boolean()
  def augmented_tools_call?(%{"method" => "tools/call", "params" => %{"task" => _}}), do: true
  def augmented_tools_call?(_), do: false

  @doc """
  Dispatches a `tasks/*` request (`tasks/get`, `tasks/result`, `tasks/cancel`,
  `tasks/list`), replying inline or registering a result waiter for
  non-terminal tasks.
  """
  @spec dispatch_request(map(), map(), GenServer.from(), state(), frame_fn()) ::
          {:reply, {:ok, binary()}, state()} | {:noreply, state()}
  def dispatch_request(%{"method" => "tasks/get", "id" => req_id} = request, _ctx, _from, state, frame_fn) do
    if is_nil(state.task_store) do
      unsupported_reply(req_id, "tasks/get", state)
    else
      frame = frame_fn.(state)

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

  def dispatch_request(
        %{"method" => "tasks/result", "id" => req_id, "params" => %{"taskId" => task_id}},
        _ctx,
        from,
        state,
        _frame_fn
      ) do
    if is_nil(state.task_store) do
      unsupported_reply(req_id, "tasks/result", state)
    else
      handle_result(task_id, req_id, from, state)
    end
  end

  def dispatch_request(%{"method" => "tasks/cancel", "id" => req_id} = request, _ctx, _from, state, frame_fn) do
    if cancel_supported?(state) do
      handle_cancel(request, state, frame_fn)
    else
      unsupported_reply(req_id, "tasks/cancel", state)
    end
  end

  def dispatch_request(%{"method" => "tasks/list", "id" => req_id}, _ctx, _from, state, frame_fn) do
    frame = frame_fn.(state)
    {:error, error, frame} = TasksHandler.handle_list_unsupported(frame)
    {:reply, {:ok, encode_reply(Error.build_json_rpc(error, req_id))}, %{state | frame: frame}}
  end

  @doc """
  Handles a task-augmented `tools/call`: validates support, tool existence,
  and tool task policy, then spawns the worker task and replies with the
  CreateTaskResult.
  """
  @spec create_for_tools_call(map(), map(), GenServer.from(), state(), frame_fn()) ::
          {:reply, {:ok, binary()}, state()}
  def create_for_tools_call(%{"id" => req_id, "params" => params} = request, _ctx, _from, state, frame_fn) do
    if supported_for_tools_call?(state) do
      do_create_for_tools_call(request, params, req_id, state, frame_fn)
    else
      error = Error.protocol(:method_not_found, %{message: "Server does not support task-augmented tools/call"})
      {:reply, {:ok, encode_reply(Error.build_json_rpc(error, req_id))}, state}
    end
  end

  @doc """
  Finalizes the task runtime for a completed worker, deriving the terminal
  status from the handler result.
  """
  @spec handle_worker_completion(String.t(), term(), state()) :: {:noreply, state()}
  def handle_worker_completion(task_id, callback_result, state) do
    {status, attrs} = derive_finalize_attrs(callback_result)
    {_task, state} = finalize_runtime(task_id, status, attrs, state)
    {:noreply, state}
  end

  @doc """
  Finalizes the task runtime as failed when its worker crashes.
  """
  @spec handle_worker_down(String.t(), term(), state()) :: {:noreply, state()}
  def handle_worker_down(task_id, reason, state) do
    error = Error.protocol(:internal_error, %{message: "Task worker crashed", reason: inspect(reason)})
    {_task, state} = finalize_runtime(task_id, :failed, [error: error, status_message: error.message], state)
    {:noreply, state}
  end

  @doc """
  Handles TTL expiry of a live task: terminates the worker, releases waiters
  with an expiry error, and deletes the task from the store.
  """
  @spec handle_expired(String.t(), state()) :: {:noreply, state()}
  def handle_expired(task_id, state) do
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

        store_delete(state, task_id)

        state = %{
          state
          | tasks: tasks,
            task_refs: if(ref, do: Map.delete(state.task_refs, ref), else: state.task_refs)
        }

        {:noreply, state}
    end
  end

  @doc """
  Returns the task ID owning the given worker monitor ref, if any.
  """
  @spec task_id_for_ref(state(), reference()) :: String.t() | nil
  def task_id_for_ref(state, ref), do: Map.get(state.task_refs, ref)

  @doc """
  Sends a `notifications/tasks/status` notification for the given task to the
  client transport.
  """
  @spec emit_status_notification(state(), String.t()) :: :ok | {:error, term()}
  def emit_status_notification(state, task_id) do
    case store_get(state, task_id) do
      {:ok, %McpTask{} = task} ->
        params = McpTask.to_protocol(task)

        with {:ok, notification} <- ServerRequests.encode_notification("notifications/tasks/status", params, state) do
          ServerRequests.send_to_transport(state.transport, notification, ServerRequests.transport_opts(state))
        end

      _ ->
        :ok
    end
  end

  @doc """
  Terminates all live task workers, demonitors them, and releases their
  waiters with the given error. Used during session termination.
  """
  @spec terminate_all(state(), Error.t()) :: :ok
  def terminate_all(%{tasks: tasks, task_supervisor: task_supervisor}, error) do
    Enum.each(tasks, fn {_task_id, %{worker_pid: pid, worker_ref: ref} = runtime} ->
      if pid, do: Task.Supervisor.terminate_child(task_supervisor, pid)
      if ref, do: Process.demonitor(ref, [:flush])
      release_waiters(runtime, error)
    end)
  end

  defp supported_for_tools_call?(state) do
    case state.capabilities do
      %{"tasks" => %{"requests" => %{"tools" => %{"call" => _}}}} -> not is_nil(state.task_store)
      _ -> false
    end
  end

  defp cancel_supported?(state) do
    case state.capabilities do
      %{"tasks" => %{"cancel" => _}} -> not is_nil(state.task_store)
      _ -> false
    end
  end

  defp clamp_ttl(nil), do: @default_task_ttl

  defp clamp_ttl(ttl) when is_integer(ttl) do
    ttl |> max(@min_task_ttl) |> min(@max_task_ttl)
  end

  defp lookup_tool(server_module, frame, tool_name) do
    server_module
    |> Handlers.get_server_tools(frame)
    |> Enum.find(&(&1.name == tool_name))
  end

  defp unsupported_reply(req_id, method, state) do
    error = Error.protocol(:method_not_found, %{message: "#{method} not supported by this server"})
    {:reply, {:ok, encode_reply(Error.build_json_rpc(error, req_id))}, state}
  end

  defp handle_result(task_id, req_id, from, state) do
    case store_get(state, task_id) do
      {:ok, %McpTask{} = task} ->
        if McpTask.terminal?(task) do
          payload = build_result_payload(task, req_id)
          {:reply, {:ok, encode_reply(payload)}, state}
        else
          {:noreply, register_result_waiter(state, task_id, from, req_id)}
        end

      {:error, :not_found} ->
        error = TasksHandler.task_not_found(task_id)
        {:reply, {:ok, encode_reply(Error.build_json_rpc(error, req_id))}, state}
    end
  end

  defp handle_cancel(%{"id" => req_id} = request, state, frame_fn) do
    frame = frame_fn.(state)
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

  defp build_result_payload(%McpTask{result: result, error: nil} = task, req_id) when not is_nil(result) do
    Message.build_response(inject_related_task(result, task.id), req_id)
  end

  defp build_result_payload(%McpTask{error: %Error{} = error, status: :failed}, req_id) do
    Error.build_json_rpc(error, req_id)
  end

  defp build_result_payload(%McpTask{error: %Error{} = error, status: :cancelled}, req_id) do
    Error.build_json_rpc(error, req_id)
  end

  defp build_result_payload(%McpTask{status: :cancelled} = task, req_id) do
    error =
      Error.execution("Task cancelled", %{taskId: task.id})

    Error.build_json_rpc(error, req_id)
  end

  defp build_result_payload(%McpTask{status: :failed} = task, req_id) do
    error =
      Error.execution("Task failed", %{taskId: task.id})

    Error.build_json_rpc(error, req_id)
  end

  defp build_result_payload(%McpTask{} = task, req_id) do
    Message.build_response(inject_related_task(%{}, task.id), req_id)
  end

  defp inject_related_task(%{} = result, task_id) do
    meta = Map.get(result, "_meta", %{})
    related = Map.put(meta, "io.modelcontextprotocol/related-task", %{"taskId" => task_id})
    Map.put(result, "_meta", related)
  end

  defp store_get(%{task_store: nil}, _id), do: {:error, :not_found}

  defp store_get(%{task_store: %{adapter: adapter, name: name}, session_id: session_id}, task_id) do
    adapter.get(name, session_id, task_id)
  end

  defp store_put(%{task_store: %{adapter: adapter, name: name}, session_id: session_id} = state, %McpTask{} = task) do
    :ok = adapter.put(name, session_id, task)
    state
  end

  defp store_update(%{task_store: %{adapter: adapter, name: name}, session_id: session_id}, task_id, fun) do
    adapter.update(name, session_id, task_id, fun)
  end

  defp store_delete(%{task_store: %{adapter: adapter, name: name}, session_id: session_id}, task_id) do
    adapter.delete(name, session_id, task_id)
  end

  defp do_create_for_tools_call(request, params, req_id, state, frame_fn) do
    tool_name = params["name"]
    frame = frame_fn.(state)
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
        spawn_worker(request, tool, params, req_id, state, frame_fn)
    end
  end

  defp spawn_worker(request, _tool, params, req_id, state, frame_fn) do
    requested_ttl = get_in(params, ["task", "ttl"])
    ttl = clamp_ttl(requested_ttl)

    task =
      McpTask.new(
        session_id: state.session_id,
        method: "tools/call",
        request_id: req_id,
        ttl: ttl,
        poll_interval: @default_task_poll_interval,
        original_params: Map.delete(params, "task")
      )

    state = store_put(state, task)

    frame = state |> frame_fn.() |> Map.put(:task_id, task.id)

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

  defp finalize_runtime(task_id, status, attrs, state) do
    {runtime, state} = pop_runtime(state, task_id)

    case store_update(state, task_id, fn task -> McpTask.transition(task, status, attrs) end) do
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

  defp pop_runtime(state, task_id) do
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
      reply = build_result_payload(task, req_id)
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
    case store_get(state, task_id) do
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
    {runtime, state} = pop_runtime(state, task_id)

    if runtime && runtime.worker_pid && Process.alive?(runtime.worker_pid) do
      _ = Task.Supervisor.terminate_child(state.task_supervisor, runtime.worker_pid)
    end

    error = Error.execution("The task was cancelled by request.", %{taskId: task_id})

    case store_update(state, task_id, fn task ->
           McpTask.transition(task, :cancelled, error: error, status_message: "The task was cancelled by request.")
         end) do
      {:ok, cancelled} ->
        release_waiters(runtime, cancelled)
        {:ok, cancelled, state}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp encode_reply(message) when is_map(message) do
    JSON.encode!(message)
  end
end
