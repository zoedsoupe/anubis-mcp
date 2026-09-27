if Code.ensure_loaded?(Plug) do
  defmodule Anubis.Server.Transport.StreamableHTTP.StatelessBinding do
    @moduledoc """
    The Streamable HTTP binding of the `:stateless` protocol era (MCP 2026-07-28
    onward).

    `Anubis.Server.Transport.StreamableHTTP.Plug` hands a request here when its
    `MCP-Protocol-Version` header names a stateless version the server declares.
    Requests of this era carry their own protocol version, client identity and
    capabilities, so nothing about them is looked up by session: there is no
    `Mcp-Session-Id` to read or mint, no `Last-Event-ID` to resume from, and no
    GET stream or DELETE to end one.

    Each request is served by a session started for it alone and stopped once it
    answers. The session monitors the request process, so a client that goes
    away takes the session with it. Serving through a session keeps the
    scheduler, telemetry and handler dispatch the legacy era already uses, while
    a fresh session per request keeps one request's assigns and client metadata
    out of the next.

    ## Header validation

    The binding mirrors body fields into headers, and the server must reject a
    request whose headers disagree with its body (`-32020`, HTTP 400):

      * `MCP-Protocol-Version` must equal `params._meta`'s
        `io.modelcontextprotocol/protocolVersion`;
      * `Mcp-Method` is required and must equal `method`;
      * `Mcp-Name` is required for `tools/call`, `prompts/get` (`params.name`)
        and `resources/read` (`params.uri`), and is compared after decoding the
        `=?base64?…?=` sentinel.

    `Mcp-Param-*` headers are not validated: they mirror tool arguments a tool
    opts into with `x-mcp-header`, which no component declares yet.

    ## Status codes

    JSON-RPC errors that the specification ties to a status keep it: `-32601`
    (method not found) is a 404; `-32020`, `-32021` and `-32022` are a 400. Any
    other result, error or not, is a 200.
    """

    use Anubis.Logging

    import Plug.Conn

    alias Anubis.MCP.Error
    alias Anubis.MCP.ID
    alias Anubis.MCP.Message
    alias Anubis.Protocol.Registry, as: ProtocolRegistry
    alias Anubis.Protocol.Schema
    alias Anubis.Server.Stateless
    alias Anubis.Server.Supervisor, as: ServerSupervisor
    alias Anubis.Server.Transport.Session
    alias Plug.Conn.Unfetched

    require Message

    @protocol_version_key Schema.protocol_version_key()
    @client_capabilities_key "io.modelcontextprotocol/clientCapabilities"
    @base64_prefix "=?base64?"
    @base64_suffix "?="

    # Error replies are small; a reply longer than this is a result, and is not
    # decoded just to learn that.
    @error_probe_bytes 4_096

    @type classification :: :legacy | {:stateless, String.t()} | {:unsupported, String.t()}

    @doc """
    Decides which era serves a request from its `MCP-Protocol-Version` header.

    A request without the header, or naming a legacy version the server
    declares, stays on the session-oriented binding. A stateless version the
    server declares is served here. Anything else is unsupported.

    ## Examples

        iex> conn = Plug.Test.conn(:post, "/")
        iex> Anubis.Server.Transport.StreamableHTTP.StatelessBinding.classify(conn, ["2026-07-28"])
        :legacy

        iex> conn = Plug.Conn.put_req_header(Plug.Test.conn(:post, "/"), "mcp-protocol-version", "2026-07-28")
        iex> Anubis.Server.Transport.StreamableHTTP.StatelessBinding.classify(conn, ["2026-07-28", "2025-11-25"])
        {:stateless, "2026-07-28"}

        iex> conn = Plug.Conn.put_req_header(Plug.Test.conn(:post, "/"), "mcp-protocol-version", "2026-07-28")
        iex> Anubis.Server.Transport.StreamableHTTP.StatelessBinding.classify(conn, ["2025-11-25"])
        {:unsupported, "2026-07-28"}
    """
    @spec classify(Plug.Conn.t(), [String.t()]) :: classification()
    def classify(conn, declared_versions) do
      case get_req_header(conn, "mcp-protocol-version") do
        [] ->
          :legacy

        [version | _] ->
          cond do
            version not in declared_versions -> {:unsupported, version}
            ProtocolRegistry.era(version) == {:ok, :stateless} -> {:stateless, version}
            true -> :legacy
          end
      end
    end

    @doc """
    Whether a server serves any stateless version over this binding.

    A server that serves none must answer an unsupported version the way a
    legacy server does, so a dual-era client falls back to `initialize` instead
    of retrying with a version from an empty list.
    """
    @spec serves_stateless?([String.t()]) :: boolean()
    def serves_stateless?(declared_versions), do: Stateless.supported_versions(declared_versions) != []

    @doc """
    Answers a request whose protocol version the server does not serve with
    `UnsupportedProtocolVersion` (`-32022`, HTTP 400), listing the stateless
    versions the client may retry with.
    """
    @spec send_unsupported(Plug.Conn.t(), String.t(), [String.t()], map()) :: Plug.Conn.t()
    def send_unsupported(conn, version, declared_versions, opts) do
      error = Error.unsupported_protocol_version(version, Stateless.supported_versions(declared_versions))

      {id, conn} = raw_request_id(conn, opts)
      send_error(conn, 400, error, id)
    end

    @doc """
    Serves one request of a stateless protocol `version`.

    `context` is the transport context the plug builds for every request; it
    travels to the session unchanged, so authorization claims and assigns reach
    the frame exactly as they do in the legacy era.
    """
    @spec call(Plug.Conn.t(), String.t(), map(), map()) :: Plug.Conn.t()
    def call(%Plug.Conn{method: "POST"} = conn, version, context, opts) do
      with :ok <- validate_accept_header(conn),
           {:ok, raw, conn} <- read_json(conn, opts) do
        admit(conn, raw, version, context, opts)
      else
        {:error, :invalid_accept_header} ->
          send_error(conn, 406, Error.protocol(:invalid_request, %{message: "Client must accept application/json"}), nil)

        {:error, reason} ->
          send_decode_error(conn, reason, nil)
      end
    end

    def call(conn, _version, _context, _opts) do
      conn
      |> put_resp_header("allow", "POST")
      |> send_error(405, Error.protocol(:method_not_found, %{message: "Method not allowed"}), nil)
    end

    # A request's _meta is checked for shape before the schema runs, so a missing
    # field is the -32602 the stateless era defines rather than a schema miss.
    defp admit(conn, raw, version, context, opts) do
      with :ok <- validate_request_meta(raw),
           {:ok, message} <- Message.validate_message(raw) do
        serve(conn, message, version, context, opts)
      else
        {:error, reason} -> send_decode_error(conn, reason, request_id(raw))
      end
    end

    defp validate_request_meta(%{"id" => _, "method" => _} = message) do
      case get_in(message, ["params", "_meta"]) do
        %{@protocol_version_key => version, @client_capabilities_key => capabilities}
        when is_binary(version) and is_map(capabilities) ->
          :ok

        _incomplete ->
          {:error, :invalid_meta}
      end
    end

    defp validate_request_meta(_message), do: :ok

    defp serve(conn, message, version, context, opts) do
      cond do
        Message.is_notification(message) ->
          send_resp(conn, 202, "")

        Message.is_request(message) ->
          case validate_headers(conn, message, version) do
            :ok -> dispatch(conn, message, context, opts)
            {:error, %Error{} = error} -> send_error(conn, 400, error, request_id(message))
          end

        true ->
          error = Error.protocol(:invalid_request, %{message: "Clients send only requests and notifications"})
          send_error(conn, 400, error, nil)
      end
    end

    defp validate_headers(conn, message, version) do
      with :ok <- match_protocol_version(message, version),
           :ok <- match_header(conn, "mcp-method", message["method"]) do
        match_name(conn, message)
      end
    end

    defp match_protocol_version(%{"params" => %{"_meta" => %{@protocol_version_key => version}}}, version), do: :ok

    defp match_protocol_version(message, version) do
      body_version = get_in(message, ["params", "_meta", @protocol_version_key])
      mismatch("MCP-Protocol-Version", version, body_version)
    end

    defp match_name(conn, %{"method" => method, "params" => params}) when method in ~w(tools/call prompts/get) do
      match_header(conn, "mcp-name", params["name"])
    end

    defp match_name(conn, %{"method" => "resources/read", "params" => params}) do
      match_header(conn, "mcp-name", params["uri"])
    end

    defp match_name(_conn, _message), do: :ok

    defp match_header(conn, header, body_value) do
      case get_req_header(conn, header) do
        [] ->
          {:error, Error.protocol(:header_mismatch, %{message: "Missing required header #{header}"})}

        [value | _] ->
          case decode_header_value(value) do
            {:ok, ^body_value} -> :ok
            {:ok, decoded} -> mismatch(header, decoded, body_value)
            :error -> {:error, Error.protocol(:header_mismatch, %{message: "Malformed #{header} header"})}
          end
      end
    end

    defp mismatch(header, header_value, body_value) do
      message = "#{header} header value #{inspect(header_value)} does not match body value #{inspect(body_value)}"
      {:error, Error.protocol(:header_mismatch, %{message: message})}
    end

    defp decode_header_value(@base64_prefix <> rest = value) do
      if String.ends_with?(rest, @base64_suffix) do
        rest
        |> binary_part(0, byte_size(rest) - byte_size(@base64_suffix))
        |> Base.decode64()
      else
        {:ok, value}
      end
    end

    defp decode_header_value(value), do: {:ok, value}

    defp dispatch(conn, message, context, opts) do
      case start_session(opts) do
        {:ok, session} ->
          try do
            conn
            |> put_resp_content_type("application/json")
            |> reply(Session.dispatch_request(session, message, context, timeout: opts.timeout), message)
          catch
            :exit, reason ->
              Logging.transport_event("session_call_failed", %{reason: reason}, level: :error)
              error = Error.protocol(:internal_error, %{message: "Server unavailable"})
              send_error(conn, 500, error, request_id(message))
          after
            stop_session(opts.server, session)
          end

        {:error, reason} ->
          Logging.transport_event("session_start_failed", %{reason: reason}, level: :error)
          send_error(conn, 500, Error.wrap_reason(reason), request_id(message))
      end
    end

    defp reply(conn, {:ok, response}, _message) when is_binary(response) do
      send_resp(conn, reply_status(response), response)
    end

    defp reply(conn, {:ok, nil}, _message), do: send_resp(conn, 202, "")

    defp reply(conn, {:error, reason}, message) do
      send_error(conn, 400, Error.wrap_reason(reason), request_id(message))
    end

    defp reply_status(response) when byte_size(response) > @error_probe_bytes, do: 200

    defp reply_status(response) do
      case JSON.decode(response) do
        {:ok, %{"error" => %{"code" => code}}} -> error_status(code)
        _ -> 200
      end
    end

    defp error_status(-32_601), do: 404
    defp error_status(code) when code in [-32_020, -32_021, -32_022], do: 400
    defp error_status(_code), do: 200

    defp start_session(%{server: server} = opts) do
      config = ServerSupervisor.get_session_config(server)

      ServerSupervisor.start_session(server,
        session_id: ID.generate_session_id(),
        server_module: server,
        transport: config.transport,
        timeout: opts.timeout,
        task_supervisor: config.task_supervisor,
        task_store: Map.get(config, :task_store),
        owner: self()
      )
    end

    defp stop_session(server, session) do
      ServerSupervisor.terminate_session(server, session)
    end

    defp validate_accept_header(conn) do
      if accepts?(conn, "application/json"), do: :ok, else: {:error, :invalid_accept_header}
    end

    # A media type is acceptable when the client names it with a quality above
    # zero (RFC 9110, section 12.4.2); `q=0` marks it unacceptable.
    defp accepts?(conn, media_type) do
      conn
      |> get_req_header("accept")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.any?(&acceptable_range?(&1, media_type))
    end

    defp acceptable_range?(range, media_type) do
      [type | params] = range |> String.split(";") |> Enum.map(&String.trim/1)
      String.downcase(type) == media_type and quality(params) > 0
    end

    defp quality(params) do
      Enum.find_value(params, 1.0, fn param ->
        with ["q", value] <- param |> String.downcase() |> String.split("=", parts: 2) |> Enum.map(&String.trim/1),
             {q, ""} <- Float.parse(value) do
          q
        else
          _other -> nil
        end
      end)
    end

    defp read_json(conn, opts) do
      with {:ok, body, conn} <- read_request_body(conn, opts),
           {:ok, raw} <- parse(body) do
        {:ok, raw, conn}
      end
    end

    # Plug.Parsers puts a top-level JSON array under "_json".
    defp parse(%{"_json" => _batch}), do: {:error, :batch}
    defp parse(body) when is_map(body), do: {:ok, body}

    defp parse(body) when is_binary(body) do
      case JSON.decode(body) do
        {:ok, message} when is_map(message) -> {:ok, message}
        {:ok, list} when is_list(list) -> {:error, :batch}
        {:ok, _other} -> {:error, :invalid_request}
        {:error, _reason} -> {:error, :parse_error}
      end
    end

    defp read_request_body(%{body_params: %Unfetched{aspect: :body_params}} = conn, %{timeout: timeout}) do
      Plug.Conn.read_body(conn, read_timeout: timeout)
    end

    defp read_request_body(%{body_params: body} = conn, _opts), do: {:ok, body, conn}

    defp send_decode_error(conn, :method_not_found, id) do
      send_error(conn, 404, Error.protocol(:method_not_found, %{message: "Method not found"}), id)
    end

    defp send_decode_error(conn, :invalid_meta, id) do
      message = "_meta must carry #{@protocol_version_key} and #{@client_capabilities_key}"
      send_error(conn, 400, Error.protocol(:invalid_params, %{message: message}), id)
    end

    defp send_decode_error(conn, :batch, id) do
      send_error(conn, 400, Error.protocol(:invalid_request, %{message: "Batched requests are not supported"}), id)
    end

    defp send_decode_error(conn, reason, id) when reason in [:parse_error, :invalid_json] do
      send_error(conn, 400, Error.protocol(:parse_error, %{message: "Parse error"}), id)
    end

    defp send_decode_error(conn, _reason, id) do
      send_error(conn, 400, Error.protocol(:invalid_request, %{message: "Invalid Request"}), id)
    end

    defp send_error(conn, status, %Error{} = error, id) do
      {:ok, body} = Error.to_json_rpc(error, id || ID.generate_error_id())

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end

    # An unsupported version cannot be decoded against its own dialect, so the id
    # is read from the raw body.
    defp raw_request_id(conn, opts) do
      case read_request_body(conn, opts) do
        {:ok, body, conn} when is_binary(body) ->
          case JSON.decode(body) do
            {:ok, message} -> {request_id(message), conn}
            _ -> {nil, conn}
          end

        {:ok, body, conn} ->
          {request_id(body), conn}

        _ ->
          {nil, conn}
      end
    end

    defp request_id(%{"id" => id}), do: id
    defp request_id(_message), do: nil
  end
end
