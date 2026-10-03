defmodule Anubis.Server.Session.ServerRequests do
  @moduledoc false

  # Internal engine for server-initiated requests (sampling, roots,
  # elicitation). State lives in the Session's server_requests map; this
  # module transforms it and performs side effects at the edges on behalf
  # of Anubis.Server.Session.
  use Anubis.Logging

  alias Anubis.MCP.ElicitationSchema
  alias Anubis.MCP.Error
  alias Anubis.MCP.ID
  alias Anubis.MCP.Message
  alias Anubis.Server.Frame

  @type kind :: :sampling | :roots | :elicitation
  @type state :: map()
  @type frame_fn :: (state() -> Frame.t())

  @doc """
  Sends a server-initiated request of the given kind to the client.

  Generates the request ID, arms the timeout timer, tracks the request in
  `state.server_requests`, validates the client capability, and encodes and
  sends the request. On any failure the timer is cancelled and the request
  untracked. `extra` is merged into the tracked request info (elicitation
  uses it for the `requested_schema` needed to validate the response), and its
  `:required_capability` key overrides the kind's default capability check.
  """
  @spec send_request(kind(), map(), non_neg_integer(), state(), map()) :: {:noreply, state()}
  def send_request(kind, params, timeout, state, extra \\ %{}) do
    config = config(kind)
    {capability, extra} = Map.pop(extra, :required_capability, config.capability)
    request_id = ID.generate_request_id()
    timer_ref = Process.send_after(self(), {config.timeout_message, request_id}, timeout)

    request_info =
      %{method: config.method, session_id: state.session_id, timer_ref: timer_ref}
      |> maybe_put_id(config.track_id, request_id)
      |> Map.merge(extra)

    state = put_in(state.server_requests[request_id], request_info)

    with :ok <- validate_client_capability(state, capability),
         {:ok, request_data} <- encode_request(config.method, params, request_id, state),
         :ok <- send_to_transport(state.transport, request_data, transport_opts(state)) do
      Logging.server_event(config.sent_event, %{request_id: request_id})
      {:noreply, state}
    else
      {:error, error} ->
        Process.cancel_timer(timer_ref)

        state = %{state | server_requests: Map.delete(state.server_requests, request_id)}

        Logging.server_event(
          config.failed_event,
          %{request_id: request_id, error: error},
          level: :error
        )

        {:noreply, state}
    end
  end

  @doc """
  Handles a timeout for a tracked server-initiated request.

  Kinds configured with `cancel_on_timeout` first attempt to notify the
  client with `notifications/cancelled` before dropping the request.
  """
  @spec handle_timeout(kind(), term(), state()) :: {:noreply, state()}
  def handle_timeout(:sampling, request_id, state), do: do_timeout(:sampling, request_id, state)

  def handle_timeout(kind, request_id, state) when is_binary(request_id) do
    do_timeout(kind, request_id, state)
  end

  @doc """
  Routes a client response for a tracked server-initiated request.

  Stops the timeout timer, untracks the request, shapes the result per the
  kind configuration, and invokes the configured server module callback
  with the frame built by `frame_fn`.
  """
  @spec handle_response(map(), state(), frame_fn()) :: {:noreply, state()} | {:stop, term(), state()}
  def handle_response(%{"id" => request_id, "result" => result}, state, frame_fn) do
    {request_info, updated_requests} = Map.pop(state.server_requests, request_id)
    Process.cancel_timer(request_info.timer_ref)

    state = %{state | server_requests: updated_requests}

    case config_for_method(request_info.method) do
      nil -> {:noreply, state}
      config -> dispatch_result(config, result, request_id, request_info, state, frame_fn)
    end
  end

  @doc """
  Handles a client error response for a tracked server-initiated request.
  """
  @spec handle_error(map(), state()) :: {:noreply, state()}
  def handle_error(%{"id" => request_id, "error" => error}, state) do
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

  @doc """
  Returns true if the given request ID belongs to a tracked server-initiated request.
  """
  @spec server_request?(term(), state()) :: boolean()
  def server_request?(request_id, %{server_requests: requests}) when is_binary(request_id) do
    Map.has_key?(requests, request_id)
  end

  def server_request?(_, _), do: false

  @doc false
  @spec transport_opts(state()) :: keyword()
  def transport_opts(state) do
    [timeout: state.timeout, session_id: state.session_id]
  end

  @doc false
  @spec send_to_transport(%{layer: module(), name: GenServer.name()} | nil, binary(), keyword()) ::
          :ok | {:error, Error.t()}
  def send_to_transport(nil, _data, _opts) do
    {:error, Error.transport(:no_transport, %{message: "No transport configured"})}
  end

  def send_to_transport(%{layer: layer, name: name}, data, opts) do
    with {:error, reason} <- layer.send_message(name, data, opts) do
      {:error, Error.transport(:send_failure, %{original_reason: reason})}
    end
  end

  @doc false
  @spec encode_notification(String.t(), map(), state()) :: {:ok, binary()} | {:error, term()}
  def encode_notification(method, params, state) do
    notification = Message.build_notification(method, params)
    Logging.message("outgoing", "notification", nil, notification)
    Message.encode_notification(notification, Message.notification_schema(protocol_module(state)))
  end

  defp do_timeout(kind, request_id, state) do
    config = config(kind)

    case Map.pop(state.server_requests, request_id) do
      {nil, _} ->
        {:noreply, state}

      {request_info, requests} ->
        state = %{state | server_requests: requests}
        maybe_notify_timeout_cancellation(config, request_info, state)
        Logging.server_event(config.timeout_event, %{request_id: request_id}, level: :warning)
        {:noreply, state}
    end
  end

  defp maybe_notify_timeout_cancellation(%{cancel_on_timeout: false}, _request_info, _state), do: :ok

  defp maybe_notify_timeout_cancellation(%{cancel_on_timeout: true} = config, %{id: request_id}, state) do
    with {:ok, notification} <-
           encode_notification(
             "notifications/cancelled",
             %{
               "requestId" => request_id,
               "reason" => "timeout"
             },
             state
           ),
         :ok <- send_to_transport(state.transport, notification, transport_opts(state)) do
      Logging.server_event(config.timeout_cancelled_event, %{request_id: request_id})
    end

    :ok
  end

  defp dispatch_result(config, result, request_id, request_info, state, frame_fn) do
    case config.transform_result.(result, request_info) do
      {:ok, payload} ->
        invoke_callback(config.callback, payload, request_id, state, frame_fn)

      {:error, reason} ->
        Logging.server_event(
          config.invalid_response_event,
          %{request_id: request_id, reason: reason},
          level: :error
        )

        {:noreply, state}
    end
  end

  defp invoke_callback(callback, payload, request_id, %{server_module: module} = state, frame_fn) do
    if Anubis.exported?(module, callback, 3) do
      frame = frame_fn.(state)

      case apply(module, callback, [payload, request_id, frame]) do
        {:noreply, new_frame} ->
          {:noreply, %{state | frame: new_frame}}

        {:stop, reason, new_frame} ->
          {:stop, reason, %{state | frame: new_frame}}
      end
    else
      {:noreply, state}
    end
  end

  defp config(kind), do: Map.fetch!(configs(), kind)

  defp config_for_method(method) do
    Enum.find_value(configs(), fn {_kind, config} ->
      if config.method == method, do: config
    end)
  end

  defp configs do
    %{
      sampling: %{
        method: "sampling/createMessage",
        capability: %{"sampling" => %{}},
        callback: :handle_sampling,
        timeout_message: :sampling_request_timeout,
        track_id: false,
        cancel_on_timeout: false,
        sent_event: "sent_sampling_request",
        failed_event: "failed_send_sampling_request",
        timeout_event: "sampling_request_timeout",
        timeout_cancelled_event: nil,
        invalid_response_event: nil,
        transform_result: fn result, _request_info -> {:ok, result} end
      },
      roots: %{
        method: "roots/list",
        capability: %{"roots" => %{}},
        callback: :handle_roots,
        timeout_message: :roots_request_timeout,
        track_id: true,
        cancel_on_timeout: true,
        sent_event: "sent_roots_request",
        failed_event: "failed_send_roots_request",
        timeout_event: "roots_request_timeout",
        timeout_cancelled_event: "roots_request_timeout_cancelled",
        invalid_response_event: nil,
        transform_result: fn result, _request_info -> {:ok, result["roots"] || []} end
      },
      elicitation: %{
        method: "elicitation/create",
        capability: %{"elicitation" => %{}},
        callback: :handle_elicitation,
        timeout_message: :elicitation_request_timeout,
        track_id: true,
        cancel_on_timeout: true,
        sent_event: "sent_elicitation_request",
        failed_event: "failed_send_elicitation_request",
        timeout_event: "elicitation_request_timeout",
        timeout_cancelled_event: "elicitation_request_timeout_cancelled",
        invalid_response_event: "invalid_elicitation_response",
        transform_result: &sanitize_elicitation_result/2
      }
    }
  end

  defp maybe_put_id(request_info, true, request_id), do: Map.put(request_info, :id, request_id)
  defp maybe_put_id(request_info, false, _request_id), do: request_info

  # A capability is declared when its key is present. A non-empty requirement
  # additionally demands that each of its keys is declared, which is how
  # elicitation modes are checked: a client declaring `elicitation: %{}` is
  # form-only by definition, so it does not satisfy a `%{"url" => %{}}` ask.
  defp validate_client_capability(state, required) when is_map(required) do
    capabilities = state.client_capabilities || %{}

    case Enum.find(Map.keys(required), &capability_missing?(capabilities, required, &1)) do
      nil -> :ok
      key -> {:error, Error.missing_required_client_capability(%{key => Map.get(required, key)})}
    end
  end

  defp capability_missing?(capabilities, required, key) do
    not capability_declared?(capabilities, key, Map.get(required, key))
  end

  defp capability_declared?(capabilities, key, required) do
    case Map.fetch(capabilities, key) do
      {:ok, _declared} when map_size(required) == 0 -> true
      {:ok, declared} when is_map(declared) -> Enum.all?(Map.keys(required), &Map.has_key?(declared, &1))
      _ -> false
    end
  end

  defp encode_request(method, params, request_id, state) do
    request = %{
      "method" => method,
      "params" => params
    }

    Logging.message("outgoing", "request", request_id, request)
    Message.encode_request(request, request_id, Message.request_schema(protocol_module(state)))
  end

  defp protocol_module(%{protocol_module: nil}), do: Anubis.Protocol.Registry.latest_module()
  defp protocol_module(%{protocol_module: protocol_module}), do: protocol_module

  # A URL-mode accept carries no content: the interaction happened out of band,
  # so an in-band payload would bypass every schema check. Clause sits before
  # the form-mode one because `%{"action" => "accept"}` also matches a map that
  # carries extra keys.
  defp sanitize_elicitation_result(%{"action" => "accept", "content" => _}, %{mode: :url}) do
    {:error, "url mode elicitation must not return content"}
  end

  defp sanitize_elicitation_result(%{"action" => "accept"} = result, %{mode: :url}) do
    {:ok, result}
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
end
