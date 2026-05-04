defmodule MockTransport do
  @moduledoc """
  Default Mox stub-with module for `Anubis.MockTransport`.

  Acts as a no-op implementation when no per-test stub is installed. Tests that
  need to observe outbound traffic install a closure-capturing stub via
  `Anubis.MCP.Case` setup, which captures the test pid and forwards every send
  as `{:mcp_send, raw_json}`.
  """

  @behaviour Anubis.Transport.Behaviour

  @impl true
  def start_link(_opts), do: {:ok, self()}

  @impl true
  def send_message(_, _, _opts \\ [timeout: 1_000]), do: :ok

  @impl true
  def shutdown(_), do: :ok

  @impl true
  def supported_protocol_versions, do: :all
end
