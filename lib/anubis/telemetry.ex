defmodule Anubis.Telemetry do
  @moduledoc """
  Telemetry events emitted by Anubis.

  Every event is namespaced under `[:anubis_mcp | event]`. The client emits
  them, the server emits them, and the transports emit their own.

  ## Attaching handlers

      :telemetry.attach_many(
        "anubis-metrics",
        [
          [:anubis_mcp, :server, :request],
          [:anubis_mcp, :server, :tool_call, :stop]
        ],
        &MyApp.Metrics.handle_event/4,
        %{}
      )

  ## Events

  Most events carry `%{system_time: System.system_time()}` as their only
  measurement; the interesting payload is in the metadata. The
  `:response` and `:error` events also carry `%{duration: elapsed_ms}`.

  ### Client

  | Event | Metadata |
  | --- | --- |
  | `[:anubis_mcp, :client, :init]` | `client_name`, `transport`, `protocol_version`, `capabilities` |
  | `[:anubis_mcp, :client, :request]` | `method`, `request_id` |
  | `[:anubis_mcp, :client, :response]` | `id`, `method`, `status`, `transport` |
  | `[:anubis_mcp, :client, :notification]` | `method`, `uri` |
  | `[:anubis_mcp, :client, :error]` | `id`, `method`, `error` |
  | `[:anubis_mcp, :client, :terminate]` | `client_name`, `reason`, `pending_requests` |
  | `[:anubis_mcp, :client, :roots]` | `action`, `request_id` |

  ### Server

  | Event | Metadata |
  | --- | --- |
  | `[:anubis_mcp, :server, :init]` | `session_id`, `capabilities`, `server_info`, `module` |
  | `[:anubis_mcp, :server, :request]` | `id` |
  | `[:anubis_mcp, :server, :response]` | `id`, `method`, `level` |
  | `[:anubis_mcp, :server, :notification]` | `method`, `server_module`, `started_at` |
  | `[:anubis_mcp, :server, :error]` | `id`, `error`, `message`, `session_id`, `stateless` |
  | `[:anubis_mcp, :server, :terminate]` | `reason` |

  ### Tool calls

  `[:anubis_mcp, :server, :tool_call]` is a `:telemetry.span/3`, so it emits
  `:start`, `:stop` and `:exception` events. See `span_tool_call/3`.

  ### Transport

  Transport events always carry `transport` (the layer, e.g. `:stdio` or
  `:streamable_http`). The rest varies by transport:

  | Event | Metadata |
  | --- | --- |
  | `[:anubis_mcp, :transport, :init]` | `transport`, `client`, `io_device` |
  | `[:anubis_mcp, :transport, :connect]` | `transport`, `client` |
  | `[:anubis_mcp, :transport, :send]` | `transport`, `client` |
  | `[:anubis_mcp, :transport, :receive]` | `transport`, `client`, `message_size` |
  | `[:anubis_mcp, :transport, :disconnect]` | `transport`, `client`, `reason` |
  | `[:anubis_mcp, :transport, :terminate]` | `transport`, `client`, `reason` |
  | `[:anubis_mcp, :transport, :error]` | `transport`, `client`, `error` |
  | `[:anubis_mcp, :transport, :sse_handler, :registered]` | `session_id`, `handler_pid`, `handler_count` (measurement) |

  Treat metadata as open: new keys may be added, so match on the ones you
  need and ignore the rest.
  """

  @default_capture_tool_payload false

  @doc """
  Execute a telemetry event with the Anubis MCP namespace.

  ## Parameters
  - `event_name` - List of atoms for the event name, excluding the :anubis_mcp prefix
  - `measurements` - Map of measurements for the event
  - `metadata` - Map of metadata for the event
  """
  @spec execute(list(atom()), map(), map()) :: :ok
  def execute(event_name, measurements, metadata) do
    :telemetry.execute([:anubis_mcp | event_name], measurements, metadata)
  end

  @doc """
  Wraps a tool call handler invocation in the `[:server, :tool_call]`
  telemetry span.

  Shared by the synchronous scheduler dispatch and the task-augmented
  `tools/call` worker path so both surface identical span data regardless
  of which route a given request took.

  The span's `:start` metadata always carries `tool`; the `:stop` metadata
  always carries `tool` and `is_error`. When
  `:telemetry_capture_tool_payload` is enabled (defaults to `false`), the
  `:start` metadata also carries `arguments` and the `:stop` metadata also
  carries `result`. See `pages/testing.md` for the rationale behind the
  opt-in default.

  ## Examples

      iex> Anubis.Telemetry.span_tool_call("get_weather", %{"city" => "NYC"}, fn -> :ok end)
      :ok
  """
  @spec span_tool_call(String.t() | nil, map() | nil, (-> result)) :: result when result: var
  def span_tool_call(tool_name, arguments, fun) do
    capture_payload? =
      Application.get_env(:anubis_mcp, :telemetry_capture_tool_payload, @default_capture_tool_payload)

    start_metadata =
      if capture_payload? do
        %{tool: tool_name, arguments: arguments}
      else
        %{tool: tool_name}
      end

    :telemetry.span(
      [:anubis_mcp | event_server_tool_call()],
      start_metadata,
      fn ->
        result = fun.()
        is_error = tool_call_error?(result)

        stop_metadata =
          if capture_payload? do
            %{tool: tool_name, is_error: is_error, result: result}
          else
            %{tool: tool_name, is_error: is_error}
          end

        {result, stop_metadata}
      end
    )
  end

  defp tool_call_error?({:error, _reason, _frame}), do: true
  defp tool_call_error?({:reply, %{"isError" => true}, _frame}), do: true
  defp tool_call_error?(_result), do: false

  # Define event name constants to ensure consistency

  # Client events
  def event_client_init, do: [:client, :init]
  def event_client_request, do: [:client, :request]
  def event_client_response, do: [:client, :response]
  def event_client_terminate, do: [:client, :terminate]
  def event_client_error, do: [:client, :error]
  def event_client_notification, do: [:client, :notification]

  # Server events
  def event_server_init, do: [:server, :init]
  def event_server_request, do: [:server, :request]
  def event_server_response, do: [:server, :response]
  def event_server_notification, do: [:server, :notification]
  def event_server_error, do: [:server, :error]
  def event_server_terminate, do: [:server, :terminate]
  def event_server_tool_call, do: [:server, :tool_call]

  # Transport events
  def event_transport_init, do: [:transport, :init]
  def event_transport_connect, do: [:transport, :connect]
  def event_transport_send, do: [:transport, :send]
  def event_transport_receive, do: [:transport, :receive]
  def event_transport_disconnect, do: [:transport, :disconnect]
  def event_transport_error, do: [:transport, :error]
  def event_transport_terminate, do: [:transport, :terminate]
  def event_transport_sse_handler_registered, do: [:transport, :sse_handler, :registered]

  # Roots events
  def event_client_roots, do: [:client, :roots]
end
