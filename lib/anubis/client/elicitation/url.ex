defmodule Anubis.Client.Elicitation.URL do
  @moduledoc false

  # URL-mode elicitation (SEP-1036). Kept apart from form mode because the two
  # barely overlap: form mode carries a `requestedSchema` and returns content,
  # URL mode carries a URL and returns an action with no content at all.

  use Anubis.Logging

  alias Anubis.Client.State
  alias Anubis.MCP.Error
  alias Anubis.MCP.Message
  alias Anubis.Telemetry

  @spec handle_request(map(), State.t()) :: State.t()
  def handle_request(%{"id" => id} = msg, state) do
    params = Map.get(msg, "params", %{})

    case State.get_url_elicitation_callback(state) do
      nil ->
        error(id, "No URL elicitation callback registered", "elicitation_not_configured", state)

      callback when is_function(callback, 3) ->
        execute_callback(id, params, callback, state)
    end
  end

  defp execute_callback(id, params, callback, state) do
    url = Map.get(params, "url", "")
    elicitation_id = Map.get(params, "elicitationId", "")
    message = Map.get(params, "message", "")

    Task.start(fn -> run_callback(id, url, elicitation_id, message, callback, state) end)

    state
  end

  defp run_callback(id, url, elicitation_id, message, callback, state) do
    case callback.(url, elicitation_id, message) do
      action when action in [:accept, :decline, :cancel] ->
        send_elicitation_response(id, %{"action" => to_string(action)}, state)

      {:error, reason} ->
        error(id, reason, "elicitation_error", state)

      other ->
        error(
          id,
          "Invalid URL elicitation callback result: #{inspect(other)}",
          "elicitation_callback_error",
          state
        )
    end
  rescue
    e ->
      error(
        id,
        "URL elicitation callback error: #{Exception.message(e)}",
        "elicitation_callback_error",
        state
      )
  end

  # An out-of-band response carries no content: the interaction happens outside
  # the client, so `accept` only records that the user consented to it.
  defp send_elicitation_response(id, result, state) do
    case Message.encode_elicitation_response(%{"result" => result}, id, State.protocol_module(state)) do
      {:ok, encoded} ->
        transport = state.transport
        :ok = transport.layer.send_message(transport.name, encoded, timeout: state.timeout)

        Telemetry.execute(
          Telemetry.event_client_response(),
          %{system_time: System.system_time()},
          %{id: id, method: "elicitation/create"}
        )

      {:error, reason} ->
        error(id, "Invalid URL elicitation response: #{inspect(reason)}", "invalid_elicitation_response", state)
    end

    state
  end

  defp error(id, message, code, %{transport: transport} = state) do
    error = %Error{code: -1, message: message, data: %{"reason" => code}}
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
