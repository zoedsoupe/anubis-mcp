# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule Anubis.Protocol.V2025_11_25 do
  @moduledoc """
  Protocol implementation for MCP specification version 2025-11-25.

  Builds on 2025-06-18, adding:
  - Tasks — durable state machines for long-running requests:
    `tasks/get`, `tasks/result`, `tasks/list`, `tasks/cancel`, and the
    `notifications/tasks/status` notification.
  """

  @behaviour Anubis.Protocol.Behaviour

  alias Anubis.Protocol.V2025_06_18

  @version "2025-11-25"

  @base_features V2025_06_18.supported_features()

  @features [:tasks | @base_features]

  @task_request_methods ~w(tasks/get tasks/result tasks/list tasks/cancel)

  @request_methods @task_request_methods ++ V2025_06_18.request_methods()

  @notification_methods ["notifications/tasks/status" | V2025_06_18.notification_methods()]

  @task_id_params %{
    "taskId" => {:required, :string}
  }

  @tasks_list_params %{
    "cursor" => :string
  }

  @task_status_notification_params %{
    "taskId" => {:required, :string},
    "status" => {:required, {:enum, ~w(working input_required completed failed cancelled)}},
    "statusMessage" => :string,
    "createdAt" => {:required, :string},
    "lastUpdatedAt" => {:required, :string},
    "ttl" => {:integer, {:gte, 0}},
    "pollInterval" => :integer
  }

  @impl true
  def version, do: @version

  @impl true
  def supported_features, do: @features

  @impl true
  def request_methods, do: @request_methods

  @impl true
  def notification_methods, do: @notification_methods

  @impl true
  def progress_params_schema do
    V2025_06_18.progress_params_schema()
  end

  @impl true
  def request_params_schema(method) when method in ~w(tasks/get tasks/result tasks/cancel) do
    @task_id_params
  end

  def request_params_schema("tasks/list"), do: @tasks_list_params

  def request_params_schema(method) do
    V2025_06_18.request_params_schema(method)
  end

  @impl true
  def notification_params_schema("notifications/tasks/status"), do: @task_status_notification_params

  def notification_params_schema(method) do
    V2025_06_18.notification_params_schema(method)
  end
end
