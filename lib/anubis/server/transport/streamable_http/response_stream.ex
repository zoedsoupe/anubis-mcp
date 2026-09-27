if Code.ensure_loaded?(Plug) do
  defmodule Anubis.Server.Transport.StreamableHTTP.ResponseStream do
    @moduledoc """
    Answers a stateless request whose handler may emit request-scoped
    notifications while it runs, such as progress.

    `Anubis.Server.Transport.StreamableHTTP.StatelessBinding` registers the
    request as the SSE handler of its session and hands it here when the client
    accepts `text/event-stream`. The request is dispatched in a task. If the
    session emits a request-scoped notification before the reply, the response
    becomes an SSE stream carrying the notifications in order and ending with
    the JSON-RPC response; otherwise it stays a single JSON object, with the
    status codes the binding gives it.

    Request-scoped means `notifications/progress`, and `notifications/message`
    when the request declared an `io.modelcontextprotocol/logLevel`. Anything
    else the session emits, such as a list change, belongs on a
    `subscriptions/listen` stream and is dropped here.

    A client that closes the stream cancels the request: the dispatch stops and
    the session, owned by the request, stops with it.
    """

    use Anubis.Logging

    alias Anubis.MCP.Error
    alias Anubis.Server.Transport.Session
    alias Anubis.SSE.Streaming

    @log_level_key "io.modelcontextprotocol/logLevel"

    @doc """
    Dispatches `message` to `session` and answers `conn`, as JSON through
    `json_reply` unless a request-scoped notification arrives first.
    """
    @spec serve(Plug.Conn.t(), pid(), map(), map(), map(), (Plug.Conn.t(), term() -> Plug.Conn.t())) :: Plug.Conn.t()
    def serve(conn, session, message, context, opts, json_reply) do
      caller = self()
      reply_ref = make_ref()

      {dispatcher, monitor} =
        spawn_monitor(fn -> send(caller, {reply_ref, dispatch(session, message, context, opts)}) end)

      await(%{
        conn: conn,
        streaming?: false,
        dispatcher: dispatcher,
        monitor: monitor,
        reply_ref: reply_ref,
        message: message,
        json_reply: json_reply,
        scoped: scoped_methods(message)
      })
    end

    defp dispatch(session, message, context, opts) do
      Session.dispatch_request(session, message, context, timeout: opts.timeout)
    catch
      :exit, reason -> {:exit, reason}
    end

    defp scoped_methods(message) do
      if get_in(message, ["params", "_meta", @log_level_key]),
        do: ["notifications/progress", "notifications/message"],
        else: ["notifications/progress"]
    end

    defp await(%{reply_ref: reply_ref, monitor: monitor} = state) do
      receive do
        {^reply_ref, result} ->
          Process.demonitor(monitor, [:flush])
          finish(state, result)

        {:DOWN, ^monitor, :process, _pid, reason} ->
          finish(state, {:exit, reason})

        {:sse_message, notification} ->
          forward(state, notification)

        {:sse_message, notification, {from, reply_ref}} ->
          send(from, {reply_ref, :ok})
          forward(state, notification)

        {:sse_message, notification, _event_id} ->
          forward(state, notification)

        :sse_keepalive when state.streaming? ->
          write(state, fn conn -> Plug.Conn.chunk(conn, ": keepalive\n\n") end)

        _other ->
          await(state)
      end
    end

    defp forward(state, notification) do
      if request_scoped?(notification, state.scoped) do
        state = open(state)
        write(state, fn conn -> Streaming.send_event(conn, String.trim_trailing(notification), nil) end)
      else
        await(state)
      end
    end

    defp request_scoped?(notification, scoped) do
      case JSON.decode(notification) do
        {:ok, %{"method" => method}} -> method in scoped
        _other -> false
      end
    end

    defp open(%{streaming?: true} = state), do: state
    defp open(state), do: %{state | conn: Streaming.prepare_connection(state.conn), streaming?: true}

    defp write(state, fun) do
      case fun.(state.conn) do
        {:ok, conn} ->
          await(%{state | conn: conn})

        {:error, reason} ->
          Logging.transport_event("response_stream_closed", %{reason: reason})
          Process.exit(state.dispatcher, :kill)
          state.conn
      end
    end

    defp finish(%{streaming?: false}, {:exit, reason}), do: exit(reason)
    defp finish(%{streaming?: false} = state, result), do: state.json_reply.(state.conn, result)

    defp finish(state, {:ok, response}) when is_binary(response) do
      case Streaming.send_event(state.conn, String.trim_trailing(response), nil) do
        {:ok, conn} -> conn
        {:error, _reason} -> state.conn
      end
    end

    defp finish(state, other) do
      error =
        case other do
          {:error, reason} -> Error.wrap_reason(reason)
          _no_reply -> Error.protocol(:internal_error, %{message: "Server unavailable"})
        end

      {:ok, encoded} = Error.to_json_rpc(error, state.message["id"])
      finish(state, {:ok, encoded})
    end
  end
end
