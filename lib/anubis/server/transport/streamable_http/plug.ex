if Code.ensure_loaded?(Plug) do
  defmodule Anubis.Server.Transport.StreamableHTTP.Plug do
    @moduledoc """
    A Plug implementation for the Streamable HTTP transport.

    This plug handles the MCP Streamable HTTP protocol as specified in MCP 2025-03-26.
    It provides a single endpoint that supports both GET and POST methods:

    - GET: Opens an SSE stream for server-to-client communication
    - POST: Handles JSON-RPC messages from client to server
    - DELETE: Closes a session

    ## Usage in Phoenix Router

        pipeline :mcp do
          plug :accepts, ["json"]
        end

        scope "/mcp" do
          pipe_through :mcp
          forward "/", to: Anubis.Server.Transport.StreamableHTTP.Plug, server: :your_server_name
        end

    ## Configuration Options

    - `:server` - The server process name (required)
    - `:session_header` - Custom header name for session ID (default: "mcp-session-id")
    - `:request_timeout` - Request timeout in milliseconds (default: 30000)
    """

    @behaviour Plug

    use Anubis.Logging

    import Plug.Conn

    alias Anubis.MCP.Error
    alias Anubis.MCP.ID
    alias Anubis.MCP.Message
    alias Anubis.Server.Registry
    alias Anubis.Server.Supervisor, as: ServerSupervisor
    alias Anubis.Server.Transport.StreamableHTTP
    alias Anubis.SSE.Streaming
    alias Plug.Conn.Unfetched

    require Message

    @default_session_header "mcp-session-id"
    @default_timeout 30_000

    # Plug callbacks

    @impl Plug
    def init(opts) do
      server = Keyword.fetch!(opts, :server)
      session_config = ServerSupervisor.get_session_config(server)
      transport_name = Registry.transport_name(server, :streamable_http)
      session_header = Keyword.get(opts, :session_header, @default_session_header)
      request_timeout = Keyword.get(opts, :request_timeout, @default_timeout)

      %{
        server: server,
        registry_mod: session_config.registry_mod,
        registry_name: Registry.registry_name(server),
        transport: transport_name,
        session_header: session_header,
        timeout: request_timeout
      }
    end

    @impl Plug
    def call(conn, opts) do
      case conn.method do
        "GET" -> handle_get(conn, opts)
        "POST" -> handle_post(conn, opts)
        "DELETE" -> handle_delete(conn, opts)
        _ -> send_error(conn, 405, "Method not allowed")
      end
    end

    # GET request handler - establishes SSE connection

    defp handle_get(conn, %{transport: transport, session_header: session_header} = opts) do
      if wants_sse?(conn) do
        session_id = get_or_create_session_id(conn, session_header)

        case StreamableHTTP.register_sse_handler(transport, session_id) do
          :ok ->
            start_sse_streaming(conn, Map.put(opts, :session_id, session_id))

          {:error, reason} ->
            Logging.transport_event("sse_registration_failed", %{reason: reason}, level: :error)

            send_error(conn, 500, "Could not establish SSE connection")
        end
      else
        send_error(conn, 406, "Accept header must include text/event-stream")
      end
    end

    # POST request handler - processes MCP messages directly to Session

    defp handle_post(conn, %{session_header: session_header} = opts) do
      with :ok <- validate_accept_header(conn),
           {:ok, body, conn} <- maybe_read_request_body(conn, opts),
           {:ok, [message]} <- maybe_parse_messages(body) do
        session_id = determine_session_id(conn, session_header, message)
        context = build_request_context(conn)

        Logging.transport_event("parsed_messages", %{
          message: message,
          session_id: session_id
        })

        process_message(conn, message, session_id, context, opts)
      else
        {:error, :invalid_accept_header} ->
          send_error(
            conn,
            406,
            "Not Acceptable: Client must accept application/json"
          )

        {:error, :invalid_json} ->
          send_jsonrpc_error(
            conn,
            Error.protocol(:parse_error, %{message: "Invalid JSON"}),
            nil
          )

        {:error, reason} ->
          Logging.transport_event("request_error", %{reason: reason}, level: :error)

          send_jsonrpc_error(
            conn,
            Error.protocol(:parse_error, %{reason: reason}),
            nil
          )
      end
    end

    defp process_message(conn, message, session_id, context, opts) do
      cond do
        Message.is_notification(message) ->
          handle_notification_message(conn, message, session_id, context, opts)

        Message.is_response(message) or Message.is_error(message) ->
          handle_response_message(conn, message, session_id, context, opts)

        Message.is_request(message) ->
          handle_request_message(conn, message, session_id, context, opts)

        true ->
          send_jsonrpc_error(
            conn,
            Error.protocol(:invalid_request, %{message: "Invalid message type"}),
            nil
          )
      end
    end

    defp handle_notification_message(conn, message, session_id, context, opts) do
      case find_session(opts, session_id) do
        {:ok, session_pid} ->
          GenServer.cast(session_pid, {:mcp_notification, message, context})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(202, "{}")

        {:error, :not_found} ->
          send_error(conn, 400, "No active session")
      end
    end

    defp handle_response_message(conn, message, session_id, context, opts) do
      case find_session(opts, session_id) do
        {:ok, session_pid} ->
          GenServer.cast(session_pid, {:mcp_response, message, context})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(202, "{}")

        {:error, :not_found} ->
          send_error(conn, 400, "No active session")
      end
    end

    defp handle_request_message(conn, message, session_id, context, opts) do
      case find_or_create_session(opts, session_id, message) do
        {:ok, session_pid} ->
          if wants_sse?(conn) do
            handle_sse_request(conn, session_pid, message, session_id, context, opts)
          else
            handle_json_request(conn, session_pid, message, session_id, context, opts)
          end

        {:error, :no_session} ->
          send_error(conn, 400, "No active session")

        {:error, reason} ->
          send_jsonrpc_error(
            conn,
            Error.protocol(:internal_error, %{reason: reason}),
            extract_request_id(message)
          )
      end
    end

    defp handle_json_request(conn, session_pid, message, session_id, context, %{session_header: session_header} = opts) do
      case GenServer.call(session_pid, {:mcp_request, message, context}, opts.timeout) do
        {:ok, response} when is_binary(response) ->
          conn
          |> put_resp_content_type("application/json")
          |> maybe_add_session_header(session_header, session_id)
          |> send_resp(200, response)

        {:ok, nil} ->
          conn
          |> put_resp_content_type("application/json")
          |> maybe_add_session_header(session_header, session_id)
          |> send_resp(200, "{}")

        {:error, error} ->
          handle_request_error(conn, error, message)
      end
    catch
      :exit, reason ->
        Logging.transport_event("session_call_failed", %{reason: reason}, level: :error)

        send_jsonrpc_error(
          conn,
          Error.protocol(:internal_error, %{message: "Server unavailable"}),
          extract_request_id(message)
        )
    end

    defp handle_sse_request(conn, session_pid, message, session_id, context, opts) do
      %{session_header: session_header} = opts

      case GenServer.call(session_pid, {:mcp_request, message, context}, opts.timeout) do
        {:ok, response} when is_binary(response) ->
          route_sse_response(conn, response, session_id, opts)

        {:ok, nil} ->
          conn
          |> put_resp_content_type("application/json")
          |> maybe_add_session_header(session_header, session_id)
          |> send_resp(200, "{}")

        {:error, error} ->
          handle_request_error(conn, error, message)
      end
    catch
      :exit, reason ->
        Logging.transport_event("session_call_failed", %{reason: reason}, level: :error)

        send_jsonrpc_error(
          conn,
          Error.protocol(:internal_error, %{message: "Server unavailable"}),
          extract_request_id(message)
        )
    end

    defp route_sse_response(conn, response, session_id, %{transport: transport} = opts) do
      handler_pid = StreamableHTTP.get_sse_handler(transport, session_id)

      cond do
        handler_pid && Process.alive?(handler_pid) ->
          send(handler_pid, {:sse_message, response})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(202, "{}")

        handler_pid ->
          StreamableHTTP.unregister_sse_handler(transport, session_id, handler_pid)
          establish_sse_for_request(conn, response, session_id, opts)

        true ->
          establish_sse_for_request(conn, response, session_id, opts)
      end
    end

    defp establish_sse_for_request(conn, response, session_id, opts) do
      %{transport: transport, session_header: session_header} = opts

      case StreamableHTTP.register_sse_handler(transport, session_id) do
        :ok ->
          handler_pid = self()
          self_pid = self()
          Task.start(fn -> send(self_pid, {:sse_message, response}) end)

          conn
          |> put_resp_header(session_header, session_id)
          |> Streaming.prepare_connection()
          |> Streaming.start(transport, session_id,
            on_close: fn ->
              StreamableHTTP.unregister_sse_handler(transport, session_id, handler_pid)
            end
          )

        {:error, reason} ->
          Logging.transport_event("sse_registration_failed", %{reason: reason}, level: :error)

          send_jsonrpc_error(
            conn,
            Error.protocol(:internal_error, %{reason: reason}),
            nil
          )
      end
    end

    defp handle_delete(conn, %{transport: transport, session_header: session_header} = opts) do
      case get_req_header(conn, session_header) do
        [session_id] when is_binary(session_id) and session_id != "" ->
          StreamableHTTP.unregister_sse_handler(transport, session_id)
          delete_session_from_store(session_id)
          stop_session_process(opts, session_id)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, "{}")

        _ ->
          send_error(conn, 400, "Session ID required")
      end
    end

    # Session management

    defp find_session(%{registry_mod: mod, registry_name: name}, session_id) do
      mod.lookup_session(name, session_id)
    end

    defp find_or_create_session(opts, session_id, message) do
      case find_session(opts, session_id) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, :not_found} when Message.is_initialize(message) ->
          start_new_session(opts, session_id)

        {:error, :not_found} ->
          {:error, :no_session}
      end
    end

    defp start_new_session(%{server: server, registry_mod: registry_mod, registry_name: registry_name} = opts, session_id) do
      session_config = ServerSupervisor.get_session_config(server)
      session_name = Registry.session_name(server, session_id)

      session_opts = [
        session_id: session_id,
        server_module: server,
        name: session_name,
        transport: session_config.transport,
        session_idle_timeout: session_config.session_idle_timeout || 1_800_000,
        timeout: opts.timeout,
        task_supervisor: session_config.task_supervisor
      ]

      case ServerSupervisor.start_session(server, session_opts) do
        {:ok, pid} ->
          registry_mod.register_session(registry_name, session_id, pid)
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # Helper functions

    defp wants_sse?(conn) do
      conn
      |> get_req_header("accept")
      |> List.first("")
      |> String.contains?("text/event-stream")
    end

    defp validate_accept_header(conn) do
      accept_header =
        conn
        |> get_req_header("accept")
        |> List.first("")

      if String.contains?(accept_header, "application/json") do
        :ok
      else
        {:error, :invalid_accept_header}
      end
    end

    defp get_or_create_session_id(conn, session_header) do
      case get_req_header(conn, session_header) do
        [session_id] when is_binary(session_id) and session_id != "" ->
          session_id

        _ ->
          ID.generate_session_id()
      end
    end

    defp determine_session_id(conn, session_header, message) when Message.is_initialize(message) do
      case get_req_header(conn, session_header) do
        [session_id] when is_binary(session_id) and session_id != "" ->
          session_id

        _ ->
          ID.generate_session_id()
      end
    end

    defp determine_session_id(conn, session_header, _message) do
      get_or_create_session_id(conn, session_header)
    end

    defp maybe_parse_messages(body) when is_binary(body) do
      case Message.decode(body) do
        {:ok, messages} ->
          {:ok, messages}

        {:error, reason} ->
          Logging.transport_event(
            "parse_error",
            %{body: body, reason: inspect(reason)},
            level: :error
          )

          {:error, :invalid_json}
      end
    end

    defp maybe_parse_messages(body) when is_map(body) do
      case Message.validate_message(body) do
        {:ok, message} -> {:ok, [message]}
        {:error, _} -> {:error, :invalid_json}
      end
    end

    defp maybe_add_session_header(conn, session_header, session_id) do
      if get_req_header(conn, session_header) == [] do
        put_resp_header(conn, session_header, session_id)
      else
        conn
      end
    end

    defp maybe_read_request_body(%{body_params: %Unfetched{aspect: :body_params}} = conn, %{timeout: timeout}) do
      case Plug.Conn.read_body(conn, read_timeout: timeout) do
        {:ok, body, conn} -> {:ok, body, conn}
        {:error, reason} -> {:error, reason}
      end
    end

    defp maybe_read_request_body(%{body_params: body} = conn, _), do: {:ok, body, conn}

    defp send_error(conn, status, message) do
      data = %{data: %{message: message, http_status: status}}

      mcp_error =
        case status do
          405 -> Error.protocol(:method_not_found, data)
          406 -> Error.protocol(:invalid_request, data)
          _ -> Error.protocol(:internal_error, data)
        end

      {:ok, error_response} = Error.to_json_rpc(mcp_error, ID.generate_error_id())

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, error_response)
    end

    defp send_jsonrpc_error(conn, %Error{} = error, id) do
      error_id = id || ID.generate_error_id()
      {:ok, encoded_error} = Error.to_json_rpc(error, error_id)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, encoded_error)
    end

    defp handle_request_error(conn, %Error{} = error, body) do
      send_jsonrpc_error(conn, error, extract_request_id(body))
    end

    defp handle_request_error(conn, reason, body) do
      Logging.transport_event("request_error", %{reason: reason}, level: :error)

      send_jsonrpc_error(
        conn,
        Error.protocol(:internal_error, %{reason: reason}),
        extract_request_id(body)
      )
    end

    defp extract_request_id(%{"id" => request_id}), do: request_id
    defp extract_request_id(_), do: nil

    defp build_request_context(conn) do
      %{
        assigns: conn.assigns,
        type: :http,
        req_headers: conn.req_headers,
        query_params: fetch_query_params_safe(conn),
        remote_ip: conn.remote_ip,
        scheme: conn.scheme,
        host: conn.host,
        port: conn.port,
        request_path: conn.request_path
      }
    end

    defp fetch_query_params_safe(conn) do
      case conn.query_params do
        %Unfetched{} -> nil
        params -> params
      end
    end

    defp start_sse_streaming(conn, params) do
      %{transport: transport, session_id: session_id, session_header: session_header} = params
      handler_pid = self()

      conn
      |> put_resp_header(session_header, session_id)
      |> Streaming.prepare_connection()
      |> Streaming.start(transport, session_id,
        on_close: fn ->
          StreamableHTTP.unregister_sse_handler(transport, session_id, handler_pid)
        end
      )
    end

    defp delete_session_from_store(session_id) do
      if store = Anubis.get_session_store_adapter() do
        store.delete(session_id, [])
      end
    end

    defp stop_session_process(%{server: server, registry_mod: registry_mod}, session_id) do
      ServerSupervisor.stop_session(server, registry_mod, session_id)
    end
  end
end
