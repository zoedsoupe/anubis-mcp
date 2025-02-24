defmodule Hermes.Client do
  @moduledoc """
  A client for interacting with a model context protocol server.
  """

  @enforce_keys [:transport, :client_info]
  defstruct [
    :transport,
    :client_info,
    :server_capabilities,
    :server_version,
    :instructions,
    capabilities: %{}
  ]

  @type t :: %__MODULE__{
          transport: pid(),
          client_info: map(),
          server_capabilities: map() | nil,
          server_version: map() | nil,
          instructions: String.t() | nil,
          capabilities: map()
        }
end
