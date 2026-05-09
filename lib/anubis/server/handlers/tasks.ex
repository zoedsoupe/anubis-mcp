defmodule Anubis.Server.Handlers.Tasks do
  @moduledoc false

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.Task

  @type session_ctx :: %{
          required(:task_store_adapter) => module(),
          required(:task_store_name) => term(),
          required(:session_id) => String.t()
        }

  @spec handle_get(map(), Frame.t(), session_ctx()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_get(%{"params" => %{"taskId" => task_id}}, frame, %{} = ctx) do
    case ctx.task_store_adapter.get(ctx.task_store_name, ctx.session_id, task_id) do
      {:ok, %Task{} = task} -> {:reply, Task.to_protocol(task), frame}
      {:error, :not_found} -> {:error, task_not_found(task_id), frame}
    end
  end

  @spec handle_list_unsupported(Frame.t()) :: {:error, Error.t(), Frame.t()}
  def handle_list_unsupported(frame) do
    {:error,
     Error.protocol(:method_not_found, %{
       message: "tasks/list is not supported in this server (no auth context binding)"
     }), frame}
  end

  @spec task_not_found(String.t()) :: Error.t()
  def task_not_found(task_id) do
    Error.protocol(:invalid_params, %{message: "Failed to retrieve task: Task not found", taskId: task_id})
  end

  @spec task_expired(String.t()) :: Error.t()
  def task_expired(task_id) do
    Error.protocol(:invalid_params, %{message: "Failed to retrieve task: Task has expired", taskId: task_id})
  end
end
