defmodule Anubis.Client.Elicitation do
  @moduledoc false

  use Anubis.Logging

  alias Anubis.Client.State
  alias Anubis.MCP.ElicitationSchema
  alias Anubis.MCP.Error
  alias Anubis.MCP.Message
  alias Anubis.Telemetry

  @spec handle_request(msg :: map(), State.t()) :: State.t()
  def handle_request(%{"id" => id} = msg, state) do
    params = Map.get(msg, "params", %{})

    case validate_elicitation_capability(state) do
      :ok ->
        handle_elicitation_with_callback(id, params, state)

      {:error, reason} ->
        send_elicitation_error(id, reason, "capability_disabled", %{}, state)
    end
  end

  defp validate_elicitation_capability(state) do
    if Map.has_key?(state.capabilities, "elicitation") do
      :ok
    else
      {:error, "Client does not have elicitation capability enabled"}
    end
  end

  defp handle_elicitation_with_callback(id, params, state) do
    case State.get_elicitation_callback(state) do
      nil ->
        send_elicitation_error(
          id,
          "No elicitation callback registered",
          "elicitation_not_configured",
          %{},
          state
        )

      callback when is_function(callback, 2) ->
        execute_elicitation_callback(id, params, callback, state)
    end
  end

  defp execute_elicitation_callback(id, params, callback, state) do
    message = Map.get(params, "message", "")
    requested_schema = Map.get(params, "requestedSchema", %{})

    Task.start(fn ->
      try do
        case callback.(message, requested_schema) do
          {:accept, content} when is_map(content) ->
            handle_accept(id, content, requested_schema, state)

          :decline ->
            send_elicitation_response(id, %{"action" => "decline"}, state)

          :cancel ->
            send_elicitation_response(id, %{"action" => "cancel"}, state)

          {:error, reason} ->
            send_elicitation_error(id, reason, "elicitation_error", %{}, state)

          other ->
            send_elicitation_error(
              id,
              "Invalid elicitation callback return: #{inspect(other)}",
              "invalid_elicitation_return",
              %{},
              state
            )
        end
      rescue
        e ->
          send_elicitation_error(
            id,
            "Elicitation callback error: #{Exception.message(e)}",
            "elicitation_callback_error",
            %{},
            state
          )
      end
    end)

    state
  end

  defp handle_accept(id, content, requested_schema, state) do
    case ElicitationSchema.validate_content(content, requested_schema) do
      :ok ->
        send_elicitation_response(id, %{"action" => "accept", "content" => content}, state)

      {:error, reason} ->
        send_elicitation_error(
          id,
          "Elicitation content does not match requested schema: #{reason}",
          "invalid_elicitation_content",
          %{},
          state
        )
    end
  end

  defp send_elicitation_response(id, result, state) do
    case Message.encode_elicitation_response(%{"result" => result}, id) do
      {:ok, encoded} ->
        transport = state.transport
        :ok = transport.layer.send_message(transport.name, encoded, timeout: state.timeout)

        Telemetry.execute(
          Telemetry.event_client_response(),
          %{system_time: System.system_time()},
          %{id: id, method: "elicitation/create"}
        )

      {:error, [%Peri.Error{} | _] = errors} ->
        send_elicitation_error(
          id,
          "Invalid elicitation response",
          "invalid_elicitation_response",
          errors,
          state
        )

      {:error, reason} ->
        send_elicitation_error(
          id,
          "Invalid elicitation response: #{inspect(reason)}",
          "invalid_elicitation_response",
          reason,
          state
        )
    end
  end

  defp send_elicitation_error(id, message, code, reason, %{transport: transport} = state) do
    error = %Error{code: -1, message: message, data: %{"reason" => reason}}
    {:ok, response} = Error.to_json_rpc(error, id)
    :ok = transport.layer.send_message(transport.name, response, timeout: state.timeout)

    Logging.client_event(
      "elicitation_error",
      %{id: id, error_code: code, error_message: message},
      level: :error
    )

    Telemetry.execute(
      Telemetry.event_client_error(),
      %{system_time: System.system_time()},
      %{id: id, method: "elicitation/create", error_code: code}
    )

    state
  end
end
