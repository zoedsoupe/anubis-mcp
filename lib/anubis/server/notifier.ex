defmodule Anubis.Server.Notifier do
  @moduledoc """
  Sends notifications and server-initiated requests back to the client that
  owns `frame`.

  Every callback receives a `Anubis.Server.Frame`, and every frame carries
  the pid of the Session serving it. These helpers use that pid, so they
  work from **any** process: the Session itself, an application process, or
  a task spawned inside a tool callback. That last case is why they exist.
  `Anubis.Server.send_tools_list_changed/0` and its siblings use
  `send(self(), ...)`, which is a no-op outside the Session process.

      defmodule MyApp.Tools.Reindex do
        use Anubis.Server.Component, type: :tool

        @impl true
        def execute(%{"job" => job}, frame) do
          MyApp.Reindex.run(job, fn step ->
            Notifier.progress(frame, step.token, step.done, total: step.total)
          end)

          {:reply, Response.tool("queued"), frame}
        end
      end

  Notifications the client may have subscribed to are dropped by the
  session when it should not receive them (see
  `send_resource_updated/3`), exactly like their `Anubis.Server`
  counterparts.

  See `Anubis.Server.Context` for `session_pid` and `request_meta`, the two
  fields these helpers read off the frame.
  """

  alias Anubis.MCP.ElicitationSchema
  alias Anubis.Server.Frame

  @typedoc "A frame handed to a server callback."
  @type frame :: Frame.t()

  @doc """
  Sends an arbitrary notification to the client.

  Every helper below is a wrapper over this. Use it directly for
  notifications Anubis has no typed helper for.

      Notifier.notify(frame, "notifications/resources/updated", %{"uri" => uri})
  """
  @spec notify(frame(), String.t(), map()) :: :ok
  def notify(frame, method, params \\ %{})

  def notify(%{context: %{session_pid: pid}}, method, params) when is_pid(pid) do
    send(pid, {:send_notification, method, params})
    :ok
  end

  @doc "Sends `notifications/resources/list_changed`."
  @spec resources_list_changed(frame()) :: :ok
  def resources_list_changed(frame), do: notify(frame, "notifications/resources/list_changed")

  @doc "Sends `notifications/prompts/list_changed`."
  @spec prompts_list_changed(frame()) :: :ok
  def prompts_list_changed(frame), do: notify(frame, "notifications/prompts/list_changed")

  @doc "Sends `notifications/tools/list_changed`."
  @spec tools_list_changed(frame()) :: :ok
  def tools_list_changed(frame), do: notify(frame, "notifications/tools/list_changed")

  @doc """
  Sends `notifications/resources/updated` for one resource.

  Subscription-gated: the session drops it unless the client previously
  sent `resources/subscribe` for this URI.
  """
  @spec resource_updated(frame(), String.t(), DateTime.t() | nil) :: :ok
  def resource_updated(frame, uri, timestamp \\ nil) do
    params = %{"uri" => uri}
    params = if timestamp, do: Map.put(params, "timestamp", timestamp), else: params

    send(session_pid!(frame), {:send_resource_update, uri, params})
    :ok
  end

  @doc "Sends `notifications/log/message`. Requires the client to declare the `:logging` capability."
  @spec log_message(frame(), Logger.level(), String.t(), map() | nil) :: :ok
  def log_message(frame, level, message, data \\ nil) do
    params = %{"level" => level, "message" => message}
    params = if data, do: Map.put(params, "data", data), else: params

    notify(frame, "notifications/log/message", params)
  end

  @doc """
  Sends `notifications/progress`.

  The token normally comes from the request's own `_meta`:

      Notifier.progress(frame, frame.context.request_meta["progressToken"], 50, total: 100)
  """
  @spec progress(frame(), String.t() | non_neg_integer(), number(), keyword()) :: :ok
  def progress(frame, progress_token, progress, opts \\ []) do
    params = %{"progressToken" => progress_token, "progress" => progress}
    params = if total = opts[:total], do: Map.put(params, "total", total), else: params
    params = if message = opts[:message], do: Map.put(params, "message", message), else: params

    notify(frame, "notifications/progress", params)
  end

  @doc """
  Sends a `sampling/createMessage` request.

  The response arrives at the server's `handle_sampling/3` callback.
  """
  @spec sampling_request(frame(), list(map()), keyword()) :: :ok
  def sampling_request(frame, messages, opts \\ []) do
    params = %{
      "messages" => messages,
      "maxTokens" => Keyword.get(opts, :max_tokens),
      "modelPreferences" => Keyword.get(opts, :model_preferences),
      "systemPrompt" => Keyword.get(opts, :system_prompt)
    }

    params = params |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

    send(session_pid!(frame), {:send_sampling_request, params, Keyword.get(opts, :timeout, 30_000)})
    :ok
  end

  @doc """
  Sends a `roots/list` request.

  The response arrives at the server's `handle_roots/3` callback.
  """
  @spec roots_request(frame(), keyword()) :: :ok
  def roots_request(frame, opts \\ []) do
    send(session_pid!(frame), {:send_roots_request, Keyword.get(opts, :timeout, 30_000)})
    :ok
  end

  @doc """
  Sends an `elicitation/create` request.

  Asks the user for structured input. `requested_schema` is validated
  before anything goes on the wire, and the session rejects the request if
  the client did not declare the `elicitation` capability. The response
  arrives at the server's `handle_elicitation/3` callback.

  Per the MCP specification, servers MUST NOT use elicitation to request
  sensitive information (credentials, payment details, anything the user
  would not type in front of a stranger).
  """
  @spec elicitation_request(frame(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def elicitation_request(frame, message, requested_schema, opts \\ [])
      when is_binary(message) and is_map(requested_schema) do
    with :ok <- ElicitationSchema.validate(requested_schema) do
      params = %{"message" => message, "requestedSchema" => requested_schema}

      send(
        session_pid!(frame),
        {:send_elicitation_request, params, requested_schema, Keyword.get(opts, :timeout, 30_000)}
      )

      :ok
    end
  end

  @doc """
  Sends a `notifications/tasks/status` carrying the current state of a task.

  Looked up in the server's task store. Per spec (2025-11-25) receivers MAY
  send these; requestors MUST NOT rely on them.
  """
  @spec task_status(frame(), String.t()) :: :ok
  def task_status(frame, task_id) when is_binary(task_id) do
    send(session_pid!(frame), {:send_task_status, task_id})
    :ok
  end

  defp session_pid!(%{context: %{session_pid: pid}}) when is_pid(pid), do: pid

  defp session_pid!(%{context: %{session_pid: nil}}) do
    raise ArgumentError, "frame has no session: notifications can only be sent from inside a session callback"
  end
end
