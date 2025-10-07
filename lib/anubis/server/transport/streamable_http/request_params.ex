defmodule Anubis.Server.Transport.StreamableHTTP.RequestParams do
  @moduledoc false

  @type t :: %__MODULE__{
          transport: GenServer.server(),
          session_id: String.t() | nil,
          session_header: String.t(),
          timeout: pos_integer(),
          context: map() | nil,
          message: map() | binary() | nil
        }

  @enforce_keys [:transport, :session_header, :timeout]
  defstruct [
    :transport,
    :session_id,
    :session_header,
    :timeout,
    :context,
    :message
  ]

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      transport: Keyword.fetch!(opts, :transport),
      session_id: Keyword.get(opts, :session_id),
      session_header: Keyword.fetch!(opts, :session_header),
      timeout: Keyword.fetch!(opts, :timeout),
      context: Keyword.get(opts, :context),
      message: Keyword.get(opts, :message)
    }
  end
end
