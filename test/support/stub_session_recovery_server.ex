defmodule StubSessionRecoveryServer do
  @moduledoc """
  Test server that implements handle_session_expired/2, supplying custom
  client info and marking the frame with a recovery flag.
  """

  use Anubis.Server,
    name: "Recovery Test Server",
    version: "1.0.0",
    capabilities: []

  import Anubis.Server.Frame, only: [assign: 3]

  alias Anubis.MCP.Error

  @impl true
  def handle_request(%{"method" => _}, frame) do
    {:error, Error.protocol(:method_not_found), frame}
  end

  @impl true
  def handle_session_expired(_session_id, frame) do
    frame =
      frame
      |> assign(:recovery_ran, true)
      |> assign(:seen_assigns, frame.assigns)
      |> assign(:seen_context, frame.context)

    {:ok, %{"name" => "recovered-client", "version" => "1.0"}, frame}
  end
end

defmodule StubSessionRecoveryRejectServer do
  @moduledoc """
  Test server that rejects session recovery via handle_session_expired/2.
  """

  use Anubis.Server,
    name: "Reject Recovery Test Server",
    version: "1.0.0",
    capabilities: []

  alias Anubis.MCP.Error

  @impl true
  def handle_request(%{"method" => _}, frame) do
    {:error, Error.protocol(:method_not_found), frame}
  end

  @impl true
  def handle_session_expired(_session_id, _frame) do
    {:error, :no_recovery_allowed}
  end
end
