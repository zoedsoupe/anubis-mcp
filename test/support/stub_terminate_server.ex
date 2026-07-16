defmodule StubTerminateServer do
  @moduledoc """
  Test server that exports terminate/2 and emits observable telemetry,
  used to prove terminate/2 runs on supervisor-initiated session stop.
  """

  use Anubis.Server,
    name: "Terminate Test Server",
    version: "1.0.0",
    capabilities: []

  alias Anubis.MCP.Error

  @impl true
  def handle_request(%{"method" => _}, frame) do
    {:error, Error.protocol(:method_not_found), frame}
  end

  @impl true
  def terminate(reason, _frame) do
    :telemetry.execute([:test, :session, :closed], %{}, %{reason: reason})
    :ok
  end
end
