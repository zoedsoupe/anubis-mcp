defmodule BufferedMockTransport do
  @moduledoc """
  A mock transport that delegates parse/encode to STDIO (for buffering)
  but stubs the GenServer behaviour. Used to test chunked STDIO responses.
  """
  @behaviour Anubis.Transport
  @behaviour Anubis.Transport.Behaviour

  alias Anubis.Transport.STDIO

  @impl true
  defdelegate transport_init(opts \\ []), to: STDIO
  @impl true
  defdelegate parse(raw, state), to: STDIO
  @impl true
  defdelegate encode(message, state), to: STDIO
  @impl true
  defdelegate extract_metadata(raw, state), to: STDIO

  @impl Anubis.Transport.Behaviour
  def start_link(_opts), do: {:ok, self()}

  @impl Anubis.Transport.Behaviour
  def send_message(_, _, _opts \\ [timeout: 1_000]), do: :ok

  @impl Anubis.Transport.Behaviour
  def shutdown(_), do: :ok

  @impl Anubis.Transport.Behaviour
  def supported_protocol_versions, do: :all
end
