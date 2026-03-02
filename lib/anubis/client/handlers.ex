defmodule Anubis.Client.Handlers do
  @moduledoc false

  use Anubis.Logging

  alias Anubis.Client.State
  alias Anubis.MCP.Error
  alias Anubis.Telemetry

  @spec handle_notification(msg :: map, State.t()) :: State.t()
  def handle_notification(%{"method" => "notifications/progress"} = notification, state) do
    handle_progress_notification(notification, state)
  end

  def handle_notification(%{"method" => "notifications/message"} = notification, state) do
    handle_log_notification(notification, state)
  end

  def handle_notification(%{"method" => "notifications/cancelled"} = notification, state) do
    handle_cancelled_notification(notification, state)
  end

  def handle_notification(%{"method" => "notifications/resources/list_changed"} = notification, state) do
    handle_resources_list_changed_notification(notification, state)
  end

  def handle_notification(%{"method" => "notifications/resources/updated"} = notification, state) do
    handle_resource_updated_notification(notification, state)
  end

  def handle_notification(%{"method" => "notifications/prompts/list_changed"} = notification, state) do
    handle_prompts_list_changed_notification(notification, state)
  end

  def handle_notification(%{"method" => "notifications/tools/list_changed"} = notification, state) do
    handle_tools_list_changed_notification(notification, state)
  end

  def handle_notification(_, state), do: state

  defp handle_cancelled_notification(%{"params" => params}, state) do
    request_id = params["requestId"]
    reason = Map.get(params, "reason", "unknown")

    {request, updated_state} = State.remove_request(state, request_id)

    if request do
      Logging.client_event("request_cancelled", %{
        id: request_id,
        reason: reason
      })

      error =
        Error.transport(:request_cancelled, %{
          message: "Request cancelled by server",
          reason: reason
        })

      GenServer.reply(request.from, {:error, error})
    end

    updated_state
  end

  defp handle_progress_notification(%{"params" => params}, state) do
    progress_token = params["progressToken"]
    progress = params["progress"]
    total = Map.get(params, "total")

    if callback = State.get_progress_callback(state, progress_token) do
      Task.start(fn -> callback.(progress_token, progress, total) end)
    end

    state
  end

  defp handle_log_notification(%{"params" => params}, state) do
    level = params["level"]
    data = params["data"]
    logger = Map.get(params, "logger")

    if callback = State.get_log_callback(state) do
      Task.start(fn -> callback.(level, data, logger) end)
    end

    log_to_logger(level, data, logger)

    state
  end

  defp log_to_logger(level, data, logger) do
    elixir_level =
      case level do
        level when level in ["debug"] -> :debug
        level when level in ["info", "notice"] -> :info
        level when level in ["warning"] -> :warning
        level when level in ["error", "critical", "alert", "emergency"] -> :error
        _ -> :info
      end

    Logging.client_event("server_log", %{level: level, data: data, logger: logger}, level: elixir_level)
  end

  defp handle_resources_list_changed_notification(_notification, state) do
    Logging.client_event("resources_list_changed", nil)

    Telemetry.execute(
      Telemetry.event_client_notification(),
      %{system_time: System.system_time()},
      %{method: "resources/list_changed"}
    )

    state
  end

  defp handle_resource_updated_notification(%{"params" => params}, state) do
    uri = params["uri"]

    Logging.client_event("resource_updated", %{uri: uri})

    Telemetry.execute(
      Telemetry.event_client_notification(),
      %{system_time: System.system_time()},
      %{method: "resources/updated", uri: uri}
    )

    state
  end

  defp handle_prompts_list_changed_notification(_notification, state) do
    Logging.client_event("prompts_list_changed", nil)

    Telemetry.execute(
      Telemetry.event_client_notification(),
      %{system_time: System.system_time()},
      %{method: "prompts/list_changed"}
    )

    state
  end

  defp handle_tools_list_changed_notification(_notification, state) do
    Logging.client_event("tools_list_changed", nil)

    Telemetry.execute(
      Telemetry.event_client_notification(),
      %{system_time: System.system_time()},
      %{method: "tools/list_changed"}
    )

    state
  end
end
