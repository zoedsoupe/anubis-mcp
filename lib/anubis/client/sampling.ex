defmodule Anubis.Client.Sampling do
  @moduledoc false

  use Anubis.Logging

  alias Anubis.Client.State
  alias Anubis.MCP.Error
  alias Anubis.MCP.Message
  alias Anubis.Telemetry

  @spec handle_request(msg :: map, State.t()) :: State.t()
  def handle_request(%{"id" => id} = msg, state) do
    params = Map.get(msg, "params", %{})

    case validate_sampling_capability(state) do
      :ok ->
        handle_sampling_with_callback(id, params, state)

      {:error, reason} ->
        send_sampling_error(id, reason, "capability_disabled", %{}, state)
    end
  end

  defp validate_sampling_capability(state) do
    if Map.has_key?(state.capabilities, "sampling") do
      :ok
    else
      {:error, "Client does not have sampling capability enabled"}
    end
  end

  defp handle_sampling_with_callback(id, params, state) do
    case State.get_sampling_callback(state) do
      nil ->
        send_sampling_error(
          id,
          "No sampling callback registered",
          "sampling_not_configured",
          %{},
          state
        )

      callback when is_function(callback, 1) ->
        execute_sampling_callback(id, params, callback, state)
    end
  end

  defp execute_sampling_callback(id, params, callback, state) do
    Task.start(fn ->
      try do
        case callback.(params) do
          {:ok, result} ->
            handle_sampling_result(id, result, state)

          {:error, message} ->
            send_sampling_error(id, message, "sampling_error", %{}, state)
        end
      rescue
        e ->
          error_message = "Sampling callback error: #{Exception.message(e)}"

          send_sampling_error(
            id,
            error_message,
            "sampling_callback_error",
            %{},
            state
          )
      end
    end)

    state
  end

  defp handle_sampling_result(id, result, state) do
    case Message.encode_sampling_response(%{"result" => result}, id) do
      {:ok, validated} ->
        send_sampling_response(id, validated, state)

      {:error, [%Peri.Error{} | _] = errors} ->
        error_message = "Invalid sampling response"

        send_sampling_error(
          id,
          error_message,
          "invalid_sampling_response",
          errors,
          state
        )

      {:error, reason} ->
        error_message = "Invalid sampling response: #{reason}"

        send_sampling_error(
          id,
          error_message,
          "invalid_sampling_response",
          reason,
          state
        )
    end
  end

  defp send_sampling_response(id, response, state) do
    transport = state.transport
    :ok = transport.layer.send_message(transport.name, response, timeout: state.timeout)

    Telemetry.execute(
      Telemetry.event_client_response(),
      %{system_time: System.system_time()},
      %{id: id, method: "sampling/createMessage"}
    )
  end

  defp send_sampling_error(id, message, code, reason, %{transport: transport} = state) do
    error = %Error{code: -1, message: message, data: %{"reason" => reason}}
    {:ok, response} = Error.to_json_rpc(error, id)
    :ok = transport.layer.send_message(transport.name, response, timeout: state.timeout)

    Logging.client_event(
      "sampling_error",
      %{
        id: id,
        error_code: code,
        error_message: message
      },
      level: :error
    )

    Telemetry.execute(
      Telemetry.event_client_error(),
      %{system_time: System.system_time()},
      %{id: id, method: "sampling/createMessage", error_code: code}
    )

    state
  end
end
