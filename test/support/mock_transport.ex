defmodule MockTransport do
  @moduledoc false
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
