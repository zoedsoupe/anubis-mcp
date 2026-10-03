# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule Anubis.Protocol.V2025_11_25 do
  @moduledoc """
  Protocol implementation for MCP specification version 2025-11-25.

  Builds on 2025-06-18, adding:
  - Tasks — durable state machines for long-running requests:
    `tasks/get`, `tasks/result`, `tasks/list`, `tasks/cancel`, and the
    `notifications/tasks/status` notification.
  - Elicitation rework — titled and multi-select enums, schema defaults on
    every primitive, URL mode (`mode: "url"` with `url` and `elicitationId`),
    and the `notifications/elicitation/complete` notification.
  """

  @behaviour Anubis.Protocol.Behaviour

  alias Anubis.MCP.ElicitationSchema
  alias Anubis.Protocol.Schema
  alias Anubis.Protocol.V2025_06_18

  @version "2025-11-25"

  @capability_keys ~w(prompts tools resources logging completion tasks)

  @base_features V2025_06_18.supported_features()

  @features [:tasks, :url_elicitation | @base_features]

  @task_request_methods ~w(tasks/get tasks/result tasks/list tasks/cancel)

  @request_methods @task_request_methods ++ V2025_06_18.request_methods()

  @notification_methods [
    "notifications/tasks/status",
    "notifications/elicitation/complete"
    | V2025_06_18.notification_methods()
  ]

  # `mode` is optional for form requests (`mode?: "form"` upstream), so the two
  # shapes are alternatives rather than a dispatch on a required field.
  @elicitation_form_params %{
    "mode" => {:enum, ~w(form)},
    "message" => {:required, :string},
    "requestedSchema" => {:required, {:custom, {ElicitationSchema, :validate_peri, [:latest]}}}
  }

  @elicitation_url_params %{
    "mode" => {:required, {:literal, "url"}},
    "message" => {:required, :string},
    "elicitationId" => {:required, :string},
    "url" => {:required, :string}
  }

  @elicitation_complete_params %{
    "elicitationId" => {:required, :string}
  }

  # `content` stays `:map`: a multi-select returns a `string[]` value, and the
  # per-property check against `requestedSchema` is what actually constrains the
  # contents. Re-deriving it here would only duplicate `ElicitationSchema`.
  # The schema is shared by both modes; the no-content rule for URL mode is
  # enforced on the receiving side, in
  # `Anubis.Server.Session.ServerRequests.sanitize_elicitation_result/2`.
  @elicitation_result_schema %{
    "action" => {:required, {:enum, ~w(accept decline cancel)}},
    "content" => :map
  }

  @task_id_params %{
    "taskId" => {:required, :string}
  }

  @tasks_list_params %{
    "cursor" => :string
  }

  @task_augmentation_params %{
    "ttl" => {:integer, {:gte, 0}}
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
  def era, do: V2025_06_18.era()

  @impl true
  def version, do: @version

  @impl true
  def supported_features, do: @features

  @impl true
  def supports_feature?(feature), do: feature in @features

  @impl true
  def transport_rules, do: V2025_06_18.transport_rules()

  @impl true
  def server_capabilities(capabilities) when is_map(capabilities) do
    Map.take(capabilities, @capability_keys)
  end

  @impl true
  def request_methods, do: @request_methods

  @impl true
  def notification_methods, do: @notification_methods

  @impl true
  def progress_params_schema do
    V2025_06_18.progress_params_schema()
  end

  @impl true
  def request_result_schema("elicitation/create"), do: @elicitation_result_schema

  def request_result_schema(method), do: V2025_06_18.request_result_schema(method)

  @impl true
  def request_message_schema do
    {:multi, :method, branches} = V2025_06_18.request_message_schema()

    branches =
      Map.merge(
        branches,
        Map.new(@task_request_methods, fn method ->
          {method, Schema.request_branch(method, request_params_schema(method))}
        end)
      )

    tools_call_branch =
      Schema.request_branch("tools/call", Schema.with_progress_meta(request_params_schema("tools/call")))

    elicitation_branch =
      Schema.request_branch("elicitation/create", Schema.with_progress_meta(request_params_schema("elicitation/create")))

    branches =
      branches
      |> Map.put("tools/call", tools_call_branch)
      |> Map.put("elicitation/create", elicitation_branch)

    {:multi, :method, branches}
  end

  @impl true
  def notification_message_schema do
    {:multi, :method, branches} = V2025_06_18.notification_message_schema()

    status_branch = Schema.notification_branch("notifications/tasks/status", @task_status_notification_params)

    complete_branch =
      Schema.notification_branch("notifications/elicitation/complete", @elicitation_complete_params)

    branches =
      branches
      |> Map.put("notifications/tasks/status", status_branch)
      |> Map.put("notifications/elicitation/complete", complete_branch)

    {:multi, :method, branches}
  end

  @impl true
  def request_params_schema(method) when method in ~w(tasks/get tasks/result tasks/cancel) do
    @task_id_params
  end

  def request_params_schema("tasks/list"), do: @tasks_list_params

  def request_params_schema("elicitation/create") do
    {:either, {@elicitation_form_params, @elicitation_url_params}}
  end

  def request_params_schema("tools/call") do
    Map.put(V2025_06_18.request_params_schema("tools/call"), "task", @task_augmentation_params)
  end

  def request_params_schema(method) do
    V2025_06_18.request_params_schema(method)
  end

  @impl true
  def notification_params_schema("notifications/tasks/status"), do: @task_status_notification_params

  def notification_params_schema("notifications/elicitation/complete"), do: @elicitation_complete_params

  def notification_params_schema(method) do
    V2025_06_18.notification_params_schema(method)
  end
end
