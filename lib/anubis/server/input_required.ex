defmodule Anubis.Server.InputRequired do
  @moduledoc """
  A result asking the client for input before a request can complete: the
  `InputRequiredResult` of the multi round-trip requests pattern (MCP
  2026-07-28).

  A `tools/call`, `prompts/get` or `resources/read` handler returns one in place
  of an `Anubis.Server.Response`. The client answers each input request under
  its key and retries the original request; the handler then reads the answers
  with `Anubis.Server.Frame.input_response/2` and, if it attached one, its state
  with `Anubis.Server.Frame.request_state/1`.

      alias Anubis.Server.{Frame, InputRequired, Response}

      @impl true
      def execute(_params, frame) do
        case Frame.input_response(frame, "confirm") do
          %{"action" => "accept"} ->
            {:reply, Response.text(Response.tool(), "Sent."), frame}

          _not_yet ->
            input =
              InputRequired.new()
              |> InputRequired.elicit("confirm", "Send the message?", %{
                "type" => "object",
                "properties" => %{"ok" => %{"type" => "boolean"}}
              })

            {:reply, input, frame}
        end
      end

  A client may answer only some requests, or none, and may never retry; a
  handler asks again for what is missing rather than failing.

  An input request needs the matching client capability (`elicitation`,
  `sampling` or `roots`). One the client did not declare is refused with
  `-32021` instead of being sent; check `Anubis.Server.Frame.client_supports?/2`
  first to offer something else. The result exists only in the stateless era;
  a handshake-era request that gets one fails with an internal error.

  State is signed by `Anubis.Server.RequestState`, which needs
  `config :anubis_mcp, :request_state_secret`.
  """

  @type t :: %__MODULE__{
          input_requests: %{String.t() => %{String.t() => term()}},
          request_state: {:set, term()} | nil
        }

  defstruct input_requests: %{}, request_state: nil

  @capabilities %{
    "elicitation/create" => "elicitation",
    "sampling/createMessage" => "sampling",
    "roots/list" => "roots"
  }

  @doc """
  Starts an empty result. It needs at least one input request or a state.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Asks the user, through a form, for content matching `requested_schema`.

  The answer is an `ElicitResult`: `%{"action" => "accept", "content" => ...}`,
  or `"decline"` / `"cancel"` without content.
  """
  @spec elicit(t(), String.t(), String.t(), map()) :: t()
  def elicit(%__MODULE__{} = input, key, message, requested_schema)
      when is_binary(message) and is_map(requested_schema) do
    put_request(input, key, "elicitation/create", %{
      "mode" => "form",
      "message" => message,
      "requestedSchema" => requested_schema
    })
  end

  @doc """
  Asks the client's model for a completion. `params` are the
  `sampling/createMessage` parameters (`"messages"`, `"maxTokens"`, ...).
  """
  @spec sample(t(), String.t(), map()) :: t()
  def sample(%__MODULE__{} = input, key, params) when is_map(params) do
    put_request(input, key, "sampling/createMessage", params)
  end

  @doc """
  Asks the client for its roots. The answer is a `ListRootsResult`.
  """
  @spec list_roots(t(), String.t()) :: t()
  def list_roots(%__MODULE__{} = input, key), do: put_request(input, key, "roots/list", %{})

  @doc """
  Attaches a state the client echoes on its retry, where
  `Anubis.Server.Frame.request_state/1` returns it. Any term; it travels signed.
  """
  @spec state(t(), term()) :: t()
  def state(%__MODULE__{} = input, term), do: %{input | request_state: {:set, term}}

  @doc """
  The client capabilities the input requests need, as a
  `requiredCapabilities` map (`%{"elicitation" => %{}}`).
  """
  @spec required_capabilities(t()) :: %{String.t() => map()}
  def required_capabilities(%__MODULE__{input_requests: requests}) do
    for {_key, %{"method" => method}} <- requests, into: %{}, do: {@capabilities[method], %{}}
  end

  defp put_request(input, key, method, params) when is_binary(key) do
    %{input | input_requests: Map.put(input.input_requests, key, %{"method" => method, "params" => params})}
  end
end
