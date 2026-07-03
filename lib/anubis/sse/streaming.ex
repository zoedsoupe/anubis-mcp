if Code.ensure_loaded?(Plug) do
  defmodule Anubis.SSE.Streaming do
    @moduledoc false

    use Anubis.Logging

    alias Anubis.SSE.Event

    @type conn :: Plug.Conn.t()
    @type transport :: GenServer.server()
    @type session_id :: String.t()

    @doc """
    Starts the SSE streaming loop for a connection.

    This function takes control of the connection and enters a receive loop,
    streaming messages to the client as they arrive.

    When an `:event_store` is supplied the stream is resumable: it opens with a
    priming event carrying a cursor, replays any events recorded after the
    client's `:resume_from` cursor, and then delivers live events using the ids
    assigned by the store. Without an `:event_store` the stream keeps the legacy
    per-connection id behavior.

    ## Parameters
      - `conn` - The Plug.Conn that has been prepared for chunked response
      - `transport` - The transport process
      - `session_id` - The session identifier
      - `opts` - Options including:
        - `:initial_event_id` - Starting event ID for the legacy path (default: 0)
        - `:on_close` - Function to call when connection closes
        - `:event_store` - `{module, name}` of the resumability store, or `nil`
        - `:resume_from` - client `Last-Event-ID` cursor, or `nil` on fresh connect
        - `:retry` - SSE `retry:` reconnect delay in milliseconds, or `nil`

    ## Messages handled
      - `{:sse_message, binary}` - Message to send to client (legacy id path)
      - `{:sse_message, binary, event_id}` - Message with a store-assigned id
      - `:close_sse` - Close the connection gracefully
    """
    @spec start(conn, transport, session_id, keyword()) :: conn
    def start(conn, transport, session_id, opts \\ []) do
      initial_event_id = Keyword.get(opts, :initial_event_id, 0)
      on_close = Keyword.get(opts, :on_close, fn -> :ok end)

      try do
        case prime_and_replay(conn, session_id, opts) do
          {:ok, conn, last_id} -> loop(conn, transport, session_id, initial_event_id, last_id)
          {:error, conn} -> conn
        end
      after
        on_close.()
      end
    end

    @doc """
    Prepares a connection for SSE streaming.

    Sets appropriate headers and starts chunked response.
    """
    @spec prepare_connection(conn) :: conn
    def prepare_connection(conn) do
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
      |> Plug.Conn.send_chunked(200)
    end

    @doc """
    Sends a single SSE event.

    This is useful for sending events outside of the main loop. A `nil` event id
    yields an event with no `id:` line, so it is not a resumption cursor.
    """
    @spec send_event(conn, binary(), non_neg_integer() | nil) ::
            {:ok, conn} | {:error, term()}
    def send_event(conn, data, event_id) when is_binary(data) do
      event = %Event{
        id: event_id_string(event_id),
        event: "message",
        data: data
      }

      case Plug.Conn.chunk(conn, Event.encode(event)) do
        {:ok, conn} -> {:ok, conn}
        {:error, reason} -> {:error, reason}
      end
    end

    # Private functions

    # A `nil` id is omitted from the wire (Event.encode drops nil fields), keeping
    # per-request POST response streams non-resumable and free of a colliding id.
    defp event_id_string(nil), do: nil
    defp event_id_string(event_id), do: to_string(event_id)

    # `event_counter` is the legacy per-connection id source (used by the 2-tuple
    # message path and the deprecated SSE transport). `last_id` is the highest
    # store-assigned id written on the resumable path; it is used to drop any
    # live message whose id was already delivered during replay, keeping delivery
    # exactly-once across the register-then-replay window.
    defp loop(conn, transport, session_id, event_counter, last_id) do
      receive do
        message -> handle_message(message, conn, transport, session_id, event_counter, last_id)
      end
    end

    defp handle_message(:sse_keepalive, conn, transport, session_id, event_counter, last_id) do
      continue(conn, keep_alive(conn), transport, session_id, event_counter + 1, last_id, "sse_keepalive_failed")
    end

    defp handle_message({:sse_message, message}, conn, transport, session_id, event_counter, last_id)
         when is_binary(message) do
      sent = send_event(conn, message, event_counter)
      continue(conn, sent, transport, session_id, event_counter + 1, last_id, "sse_send_failed")
    end

    defp handle_message({:sse_message, message, event_id}, conn, transport, session_id, event_counter, last_id)
         when is_binary(message) and is_integer(event_id) and event_id > last_id do
      # Resumable path: the transport assigned and recorded the id before routing,
      # so we write exactly that id and leave the legacy counter untouched.
      sent = send_event(conn, message, event_id)
      continue(conn, sent, transport, session_id, event_counter, event_id, "sse_send_failed")
    end

    defp handle_message({:sse_message, _message, event_id}, conn, transport, session_id, event_counter, last_id)
         when is_integer(event_id) do
      # Already delivered during replay (id <= last_id). Drop the duplicate.
      loop(conn, transport, session_id, event_counter, last_id)
    end

    defp handle_message({:sse_message, message, {from, ref}}, conn, transport, session_id, event_counter, last_id)
         when is_binary(message) do
      case send_event(conn, message, event_counter) do
        {:ok, conn} ->
          send(from, {ref, :ok})
          loop(conn, transport, session_id, event_counter + 1, last_id)

        {:error, reason} ->
          Logging.transport_event("sse_send_failed", %{session_id: session_id, reason: reason}, level: :warning)
          send(from, {ref, {:error, reason}})
          conn
      end
    end

    defp handle_message(:close_sse, conn, _transport, session_id, _event_counter, _last_id) do
      Logging.transport_event("sse_closing", %{session_id: session_id})
      Plug.Conn.halt(conn)
    end

    defp handle_message({:plug_conn, :sent}, conn, transport, session_id, event_counter, last_id) do
      # Ignore Plug internal messages
      loop(conn, transport, session_id, event_counter, last_id)
    end

    defp handle_message(msg, conn, transport, session_id, event_counter, last_id) do
      Logging.transport_event("sse_unknown_message", %{session_id: session_id, message: inspect(msg)}, level: :warning)
      loop(conn, transport, session_id, event_counter, last_id)
    end

    # Continues the loop after a chunk write, or logs and returns the last good
    # conn on failure (the loop is abandoned and Plug finalizes the response).
    defp continue(_prev, {:ok, conn}, transport, session_id, event_counter, last_id, _event) do
      loop(conn, transport, session_id, event_counter, last_id)
    end

    defp continue(conn, {:error, reason}, _transport, session_id, _event_counter, _last_id, event) do
      Logging.transport_event(event, %{session_id: session_id, reason: reason}, level: :warning)
      conn
    end

    defp keep_alive(conn) do
      Plug.Conn.chunk(conn, ": keepalive\n\n")
    end

    # Opens a resumable stream: send the priming event, then replay any recorded
    # events after the client's cursor. A `nil` :event_store is the legacy path
    # (no priming, no replay). Returns {:ok, conn, last_id} to enter the loop
    # (where last_id is the highest id actually written during replay, 0 if none),
    # or {:error, conn} to abort the stream.
    defp prime_and_replay(conn, session_id, opts) do
      case Keyword.get(opts, :event_store) do
        nil -> {:ok, conn, 0}
        {_mod, _name} = store -> prime_store(conn, store, session_id, opts)
      end
    end

    defp prime_store(conn, store, session_id, opts) do
      resume_from = Keyword.get(opts, :resume_from)
      retry = Keyword.get(opts, :retry)

      case priming_id(store, session_id, resume_from) do
        {:ok, priming_id} ->
          with {:ok, conn} <- send_priming_event(conn, priming_id, retry) do
            replay_events(conn, store, session_id, resume_from)
          end

        {:error, reason} ->
          # Fail closed: a store that cannot report its high-water mark must not
          # prime the client with a fabricated cursor and enter the live loop.
          # The client reconnects/re-inits.
          Logging.transport_event("sse_priming_aborted", %{session_id: session_id, reason: inspect(reason)},
            level: :warning
          )

          {:error, conn}
      end
    end

    # Primes the client with a cursor from the first byte, as the spec's
    # resumability model requires. Empty data means the client updates its
    # last-event-id without dispatching a message. On reconnect the priming id
    # echoes the client's own cursor so a drop before replay cannot skip events.
    defp send_priming_event(conn, event_id, retry) do
      event = %Event{id: to_string(event_id), event: "", data: "", retry: retry}

      case Plug.Conn.chunk(conn, Event.encode(event)) do
        {:ok, conn} ->
          {:ok, conn}

        {:error, reason} ->
          Logging.transport_event("sse_priming_failed", %{reason: inspect(reason)}, level: :warning)
          {:error, conn}
      end
    end

    # The dedupe floor (last_id) is the highest id ACTUALLY replayed on this
    # connection (0 when nothing was replayed), never the client's cursor. Seeding
    # it from an untrusted or stale Last-Event-ID would drop every live event whose
    # store id is below that cursor (e.g. after a store reset or a bogus cursor).
    defp replay_events(conn, _store, _session_id, nil), do: {:ok, conn, 0}

    defp replay_events(conn, {mod, name}, session_id, resume_from) do
      case mod.replay(name, session_id, resume_from) do
        {:ok, events} ->
          Enum.reduce_while(events, {:ok, conn, 0}, &write_replayed_event/2)

        {:error, reason} ->
          # Fail closed: do not prime the client into believing it resumed when
          # the recorded events could not be read. The client reconnects/re-inits.
          Logging.transport_event("sse_replay_failed", %{session_id: session_id, reason: inspect(reason)},
            level: :warning
          )

          {:error, conn}
      end
    end

    defp write_replayed_event({id, data}, {:ok, conn, _last}) do
      case send_event(conn, data, id) do
        {:ok, conn} -> {:cont, {:ok, conn, id}}
        {:error, _reason} -> {:halt, {:error, conn}}
      end
    end

    # The client's own cursor (resume_from) is the priming id when present;
    # otherwise ask the store for the session high-water. A store error is
    # propagated so the caller can abort rather than fabricate a 0 cursor.
    defp priming_id(_store, _session_id, resume_from) when is_integer(resume_from), do: {:ok, resume_from}

    defp priming_id({mod, name}, session_id, nil) do
      mod.latest_id(name, session_id)
    end
  end
end
