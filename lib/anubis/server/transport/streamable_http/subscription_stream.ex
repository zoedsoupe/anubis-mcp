if Code.ensure_loaded?(Plug) do
  defmodule Anubis.Server.Transport.StreamableHTTP.SubscriptionStream do
    @moduledoc """
    The response stream of a stateless-era `subscriptions/listen` request.

    `Anubis.Server.Transport.StreamableHTTP.StatelessBinding` hands a stream
    here once the session has decided which notifications it honors. The
    stream opens with `notifications/subscriptions/acknowledged` carrying that
    filter, then forwards what the session emits through the transport, and
    only what the filter names:

      * `notifications/tools/list_changed`, `notifications/prompts/list_changed`
        and `notifications/resources/list_changed` when their flag was honored;
      * `notifications/resources/updated` for an honored URI.

    Every message on the stream carries the subscription id, the JSON-RPC id
    of the `subscriptions/listen` request, under `_meta`. Notifications a
    server emits for its own requests, such as progress or log messages, never
    reach this stream.

    The stream ends when the client closes it, or, gracefully, with a
    completion result for the `subscriptions/listen` request when the session
    stops or the transport closes it.
    """

    use Anubis.Logging

    alias Anubis.MCP.Message
    alias Anubis.Protocol.Schema
    alias Anubis.SSE.Streaming

    @subscription_id_key Schema.subscription_id_key()

    @list_changed %{
      "notifications/tools/list_changed" => "toolsListChanged",
      "notifications/prompts/list_changed" => "promptsListChanged",
      "notifications/resources/list_changed" => "resourcesListChanged"
    }

    @doc """
    Streams the subscription on `conn` until it ends, and returns the conn.

    `session` is the process whose notifications the transport routes to the
    calling process; its exit ends the stream gracefully. `honored` is the
    filter the session agreed to, and `protocol_module` the dialect the
    notifications are validated against.
    """
    @spec serve(Plug.Conn.t(), pid(), String.t() | integer(), map(), module()) :: Plug.Conn.t()
    def serve(conn, session, subscription_id, honored, protocol_module) do
      state = %{
        conn: Streaming.prepare_connection(conn),
        session_ref: Process.monitor(session),
        id: subscription_id,
        honored: honored,
        schema: Message.notification_schema(protocol_module)
      }

      acknowledgment = %{
        "method" => "notifications/subscriptions/acknowledged",
        "params" => %{"notifications" => honored}
      }

      case emit(state, acknowledgment) do
        {:ok, state} -> loop(state)
        {:error, state} -> state.conn
      end
    end

    defp loop(state) do
      receive do
        {:sse_message, message} -> forward(state, message)
        {:sse_message, message, {from, ref}} -> forward(state, message, fn result -> send(from, {ref, result}) end)
        {:sse_message, message, _event_id} -> forward(state, message)
        :sse_keepalive -> continue(state, Plug.Conn.chunk(state.conn, ": keepalive\n\n"))
        :close_sse -> close(state)
        {:DOWN, ref, :process, _pid, _reason} when ref == state.session_ref -> close(state)
        _other -> loop(state)
      end
    end

    defp forward(state, message, ack \\ fn _result -> :ok end) do
      case deliver(state, message) do
        {:ok, state} ->
          ack.(:ok)
          loop(state)

        {:error, state} ->
          ack.({:error, :closed})
          state.conn
      end
    end

    defp deliver(state, message) do
      case JSON.decode(message) do
        {:ok, %{"method" => _} = notification} ->
          if honored?(notification, state.honored), do: emit(state, notification), else: {:ok, state}

        _other ->
          {:ok, state}
      end
    end

    defp honored?(%{"method" => "notifications/resources/updated", "params" => %{"uri" => uri}}, honored) do
      uri in Map.get(honored, "resourceSubscriptions", [])
    end

    defp honored?(%{"method" => method}, honored) do
      case Map.fetch(@list_changed, method) do
        {:ok, flag} -> Map.get(honored, flag) == true
        :error -> false
      end
    end

    defp emit(state, notification) do
      params =
        notification
        |> Map.get("params", %{})
        |> Map.update("_meta", %{@subscription_id_key => state.id}, &Map.put(&1, @subscription_id_key, state.id))

      case Message.encode_notification(Map.put(notification, "params", params), state.schema) do
        {:ok, encoded} -> write(state, encoded)
        {:error, reason} -> skip(state, notification, reason)
      end
    end

    defp skip(state, notification, reason) do
      Logging.transport_event(
        "subscription_notification_invalid",
        %{method: notification["method"], reason: inspect(reason)},
        level: :warning
      )

      {:ok, state}
    end

    defp close(state) do
      result = %{"resultType" => "complete", "_meta" => %{@subscription_id_key => state.id}}

      case Message.encode_response(%{"result" => result}, state.id) do
        {:ok, encoded} -> elem(write(state, encoded), 1).conn
        {:error, _reason} -> state.conn
      end
    end

    defp write(state, encoded) do
      case Streaming.send_event(state.conn, String.trim_trailing(encoded), nil) do
        {:ok, conn} ->
          {:ok, %{state | conn: conn}}

        {:error, reason} ->
          Logging.transport_event("subscription_stream_closed", %{reason: reason})
          {:error, state}
      end
    end

    defp continue(state, {:ok, conn}), do: loop(%{state | conn: conn})
    defp continue(state, {:error, _reason}), do: state.conn
  end
end
