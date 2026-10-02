defmodule Anubis.Transport.Behaviour do
  @moduledoc """
  Defines the behaviour that all transport implementations must follow.

  Two kinds of callbacks:

    * **Process callbacks** (`start_link/1`, `send_message/3`, `shutdown/1`) —
      the GenServer-oriented I/O contract, required.
    * **Functional callbacks** (`transport_init/1`, `parse/2`, `encode/2`,
      `extract_metadata/2`) — pure message framing used when the transport
      owns a parse state (newline-delimited JSON, SSE chunks, HTTP bodies).
      Optional; the client checks `function_exported?/3` before using them.
  """

  alias Anubis.MCP.Error

  @type t :: GenServer.server()
  @typedoc "The JSON-RPC message encoded"
  @type message :: String.t()
  @type reason :: term() | Error.t()
  @type transport_state :: term()
  @type raw_message :: binary()

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback send_message(t(), message(), list(opt)) :: :ok | {:error, reason()}
            when opt: {:timeout, pos_integer()} | {:session_id, String.t()}
  @callback shutdown(t()) :: :ok | {:error, reason()}

  @doc """
  Returns the list of MCP protocol versions supported by this transport.

  ## Examples

      iex> MyTransport.supported_protocol_versions()
      ["2025-03-26", "2025-06-18"]
  """
  @callback supported_protocol_versions() :: [String.t()] | :all

  @doc """
  Initialize transport-specific state (parse options, configure connection).
  """
  @callback transport_init(keyword()) :: {:ok, transport_state()} | {:error, term()}

  @doc """
  Parse raw input into decoded MCP message(s).

  For STDIO, raw input is newline-delimited JSON.
  For HTTP, raw input is a JSON body string or already-parsed map.
  For SSE, raw input is SSE event data.
  """
  @callback parse(raw_message() | map(), transport_state()) ::
              {:ok, [map()], transport_state()} | {:error, term()}

  @doc """
  Encode an MCP message map for this transport's wire format.

  Returns the encoded binary ready to be sent.
  """
  @callback encode(message :: map(), transport_state()) ::
              {:ok, raw_message(), transport_state()} | {:error, term()}

  @doc """
  Extract transport-specific metadata from raw input.

  For HTTP, this extracts session_id from headers, request context, etc.
  For STDIO, this returns basic process metadata.
  """
  @callback extract_metadata(raw_input :: term(), transport_state()) :: map()

  @optional_callbacks transport_init: 1, parse: 2, encode: 2, extract_metadata: 2
end
