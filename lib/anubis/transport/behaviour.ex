defmodule Anubis.Transport.Behaviour do
  @moduledoc """
  Defines the behavior that all transport implementations must follow.
  """

  alias Anubis.MCP.Error

  @type t :: GenServer.server()
  @typedoc "The JSON-RPC message encoded"
  @type message :: String.t()
  @type reason :: term() | Error.t()

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback send_message(t(), message()) :: :ok | {:error, reason()}
  @callback send_message(t(), message(), keyword()) :: :ok | {:error, reason()}
  @callback shutdown(t()) :: :ok | {:error, reason()}

  @optional_callbacks send_message: 3

  @doc """
  Returns the list of MCP protocol versions supported by this transport.

  ## Examples

      iex> MyTransport.supported_protocol_versions()
      ["2024-11-05", "2025-03-26"]
  """
  @callback supported_protocol_versions() :: [String.t()] | :all
end
