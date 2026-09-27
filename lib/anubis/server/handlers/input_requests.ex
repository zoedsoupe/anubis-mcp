defmodule Anubis.Server.Handlers.InputRequests do
  @moduledoc false

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.InputRequired
  alias Anubis.Server.RequestState
  alias Anubis.Server.Stateless

  @type binding :: RequestState.binding()

  @doc """
  Puts a retry's `inputResponses` and verified `requestState` on the frame
  before its handler runs.

  A response that is not an object is dropped rather than rejected, so the
  handler sees it as unanswered and asks again. A state that fails
  verification is refused with `-32602`.
  """
  @spec admit(map(), Frame.t(), binding()) :: {:ok, Frame.t()} | {:error, Error.t(), Frame.t()}
  def admit(request, %Frame{} = frame, binding) do
    params = request["params"] || %{}
    responses = answered(params["inputResponses"])
    frame = %{frame | context: %{frame.context | request_digest: digest(params)}}

    case verify_state(params["requestState"], frame, binding) do
      {:ok, state} ->
        {:ok, %{frame | context: %{frame.context | input_responses: responses, request_state: state}}}

      {:error, reason} ->
        {:error, Error.protocol(:invalid_params, %{message: "Invalid requestState", reason: reason}), frame}
    end
  end

  @doc """
  Turns a handler's `Anubis.Server.InputRequired` into the result sent to the
  client, or the error that stands in for it.
  """
  @spec respond(InputRequired.t(), Frame.t(), binding()) :: {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def respond(%InputRequired{} = input, %Frame{} = frame, binding) do
    missing =
      Map.reject(InputRequired.required_capabilities(input), fn {cap, _} -> Frame.client_supports?(frame, cap) end)

    cond do
      Stateless.era(frame.context.protocol_module) != :stateless ->
        internal_error(frame, "InputRequiredResult needs a request of the stateless protocol era")

      input.input_requests == %{} and is_nil(input.request_state) ->
        internal_error(frame, "InputRequiredResult needs at least one input request or a state")

      missing != %{} ->
        {:error, Error.missing_required_client_capability(missing), frame}

      true ->
        {:reply, result(input, frame, binding), frame}
    end
  end

  defp result(input, frame, binding) do
    %{"resultType" => "input_required"}
    |> put_unless_empty("inputRequests", input.input_requests)
    |> put_state(input.request_state, frame, binding)
  end

  defp put_unless_empty(result, _key, value) when value == %{}, do: result
  defp put_unless_empty(result, key, value), do: Map.put(result, key, value)

  defp put_state(result, nil, _frame, _binding), do: result

  defp put_state(result, {:set, term}, frame, binding),
    do: Map.put(result, "requestState", RequestState.sign(term, frame, binding))

  defp digest(params) do
    salient = Map.drop(params, ["_meta", "inputResponses", "requestState"])
    :crypto.hash(:sha256, :erlang.term_to_binary(salient, [:deterministic]))
  end

  defp verify_state(nil, _frame, _binding), do: {:ok, nil}
  defp verify_state(token, frame, binding) when is_binary(token), do: RequestState.verify(token, frame, binding)
  defp verify_state(_other, _frame, _binding), do: {:error, :invalid}

  defp answered(responses) when is_map(responses),
    do: Map.filter(responses, fn {key, value} -> is_binary(key) and is_map(value) end)

  defp answered(_other), do: %{}

  defp internal_error(frame, message), do: {:error, Error.protocol(:internal_error, %{message: message}), frame}
end
