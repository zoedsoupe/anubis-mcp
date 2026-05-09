defmodule Anubis.Server.Task do
  @moduledoc """
  Represents an MCP task — a durable state machine wrapping a long-running request.

  Spec reference: <https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks>.

  Tasks are receiver-owned: when a server accepts a task-augmented request (e.g.
  `tools/call` with a `task` field), it generates a task id, runs the work
  asynchronously, and exposes the lifecycle through the `tasks/get`,
  `tasks/result`, and `tasks/cancel` operations.
  """

  alias Anubis.MCP.Error

  @type status :: :working | :input_required | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          method: String.t(),
          request_id: String.t() | integer(),
          status: status(),
          status_message: String.t() | nil,
          created_at: DateTime.t(),
          last_updated_at: DateTime.t(),
          ttl: pos_integer() | nil,
          poll_interval: pos_integer() | nil,
          result: term() | nil,
          error: Error.t() | nil,
          original_params: map() | nil
        }

  defstruct [
    :id,
    :session_id,
    :method,
    :request_id,
    :created_at,
    :last_updated_at,
    :ttl,
    :poll_interval,
    :result,
    :error,
    :original_params,
    status: :working,
    status_message: nil
  ]

  @terminal_statuses ~w(completed failed cancelled)a

  @doc """
  Generates a cryptographically-strong task id.

  Per spec: receivers MUST use enough entropy to prevent guessing when no
  authorization context is bound to the task.
  """
  @spec generate_id() :: String.t()
  def generate_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Builds a fresh task in `:working` status.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, &generate_id/0),
      session_id: Keyword.fetch!(opts, :session_id),
      method: Keyword.fetch!(opts, :method),
      request_id: Keyword.fetch!(opts, :request_id),
      status: :working,
      status_message: Keyword.get(opts, :status_message),
      created_at: now,
      last_updated_at: now,
      ttl: Keyword.get(opts, :ttl),
      poll_interval: Keyword.get(opts, :poll_interval),
      original_params: Keyword.get(opts, :original_params)
    }
  end

  @doc """
  Returns true when the task is in a terminal status.
  """
  @spec terminal?(t() | status()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses
  def terminal?(status) when is_atom(status), do: status in @terminal_statuses

  @doc """
  Transitions the task into a new status. The caller is responsible for
  enforcing the FSM (`working ↔ input_required → terminal`).
  """
  @spec transition(t(), status(), keyword()) :: t()
  def transition(%__MODULE__{} = task, status, opts \\ []) do
    %{
      task
      | status: status,
        status_message: Keyword.get(opts, :status_message, task.status_message),
        last_updated_at: DateTime.utc_now(),
        result: Keyword.get(opts, :result, task.result),
        error: Keyword.get(opts, :error, task.error)
    }
  end

  @doc """
  Builds the wire-format `Task` projection used by `tasks/*` responses and the
  `notifications/tasks/status` notification. Excludes the underlying result.
  """
  @spec to_protocol(t()) :: map()
  def to_protocol(%__MODULE__{} = task) do
    base = %{
      "taskId" => task.id,
      "status" => Atom.to_string(task.status),
      "createdAt" => DateTime.to_iso8601(task.created_at),
      "lastUpdatedAt" => DateTime.to_iso8601(task.last_updated_at)
    }

    base
    |> maybe_put("statusMessage", task.status_message)
    |> maybe_put("ttl", task.ttl)
    |> maybe_put("pollInterval", task.poll_interval)
  end

  @doc """
  Wraps the task projection inside the `CreateTaskResult` envelope returned to
  the requestor at task creation time.
  """
  @spec to_create_result(t()) :: map()
  def to_create_result(%__MODULE__{} = task) do
    %{"task" => to_protocol(task)}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
