defmodule Anubis.Transport do
  @moduledoc """
  Functional behaviour for MCP transport implementations.

  Unlike `Anubis.Transport.Behaviour` (which defines a GenServer-oriented transport
  interface), this behaviour defines a **functional** transport interface for
  parsing, encoding, sending messages, and extracting metadata.

  Transport modules implementing this behaviour provide pure functions for
  message framing — the actual I/O process (Port, Plug conn, SSE handler) already
  exists and calls these functions internally.

  ## Adapters

  - `Anubis.Transport.STDIO` — newline-delimited JSON over stdin/stdout (client)
  - `Anubis.Transport.StreamableHTTP` — JSON over HTTP request/response bodies (client)
  - `Anubis.Transport.SSE` — JSON wrapped in SSE event format (client)

  ## Example

      {:ok, state} = MyTransport.transport_init(opts)
      {:ok, message, state} = MyTransport.parse(raw_data, state)
      {:ok, encoded, state} = MyTransport.encode(response, state)
  """

  @type transport_state :: term()
  @type raw_message :: binary()

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
end
