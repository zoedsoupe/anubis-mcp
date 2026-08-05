if Code.ensure_loaded?(Plug) do
  defmodule Anubis.Server.Transport.StreamableHTTP.Stateless do
    @moduledoc false

    import Plug.Conn

    alias Anubis.MCP.Error
    alias Anubis.MCP.ID
    alias Anubis.MCP.Message
    alias Anubis.Server.Discovery
    alias Plug.Conn.Unfetched

    require Message

    @protocol_version_meta "io.modelcontextprotocol/protocolVersion"
    @named_methods %{
      "tools/call" => "name",
      "prompts/get" => "name",
      "resources/read" => "uri"
    }

    @spec handle(Plug.Conn.t(), map(), module()) :: Plug.Conn.t()
    def handle(conn, opts, protocol_module) do
      case validate_origin(conn) do
        :ok ->
          handle_method(conn, opts, protocol_module)

        {:error, reason} ->
          send_protocol_error(conn, 403, Error.protocol(:invalid_request, %{reason: reason}), nil)
      end
    end

    defp handle_method(%{method: "POST"} = conn, opts, protocol_module) do
      with :ok <- validate_content_types(conn),
           {:ok, body, conn} <- read_request_body(conn, opts),
           {:ok, message} <- decode_request(body, protocol_module),
           :ok <- validate_standard_headers(conn, message) do
        dispatch(conn, message, opts.server, protocol_module)
      else
        {:error, :invalid_accept_header} ->
          send_protocol_error(
            conn,
            406,
            Error.protocol(:invalid_request, %{message: "Accept must include application/json and text/event-stream"}),
            nil
          )

        {:error, :invalid_content_type} ->
          send_protocol_error(
            conn,
            415,
            Error.protocol(:invalid_request, %{message: "Content-Type must be application/json"}),
            nil
          )

        {:error, :parse_error, body} ->
          send_protocol_error(conn, 400, Error.protocol(:parse_error), extract_request_id(body))

        {:error, :method_not_found, body} ->
          send_protocol_error(conn, 404, Error.protocol(:method_not_found), extract_request_id(body))

        {:error, :invalid_request, body} ->
          send_protocol_error(conn, 400, Error.protocol(:invalid_request), extract_request_id(body))

        {:error, {:header_mismatch, data}, message} ->
          send_protocol_error(conn, 400, Error.protocol(:header_mismatch, data), extract_request_id(message))

        {:error, reason} ->
          send_protocol_error(conn, 400, Error.wrap_reason(reason), nil)
      end
    end

    defp handle_method(conn, _opts, _protocol_module) do
      send_protocol_error(
        conn,
        405,
        Error.protocol(:method_not_found, %{message: "Stateless MCP only accepts POST"}),
        nil
      )
    end

    defp dispatch(conn, %{"method" => "server/discover", "id" => id}, server, protocol_module) do
      {:ok, response} = Message.encode_response(%{"result" => Discovery.result(server, protocol_module)}, id)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, response)
    end

    defp dispatch(conn, %{"method" => method, "id" => id}, _server, _protocol_module) do
      send_protocol_error(conn, 404, Error.protocol(:method_not_found, %{method: method}), id)
    end

    defp validate_content_types(conn) do
      accepted_types =
        conn
        |> get_req_header("accept")
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&media_type/1)

      content_type =
        conn
        |> get_req_header("content-type")
        |> List.first("")
        |> media_type()

      cond do
        content_type != "application/json" -> {:error, :invalid_content_type}
        "application/json" not in accepted_types -> {:error, :invalid_accept_header}
        "text/event-stream" not in accepted_types -> {:error, :invalid_accept_header}
        true -> :ok
      end
    end

    defp media_type(value) do
      value
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()
    end

    defp validate_standard_headers(conn, message) do
      metadata_version = get_in(message, ["params", "_meta", @protocol_version_meta])

      with :ok <- header_matches(conn, "mcp-protocol-version", metadata_version),
           :ok <- header_matches(conn, "mcp-method", message["method"]),
           :ok <- validate_name_header(conn, message) do
        :ok
      else
        {:error, data} -> {:error, {:header_mismatch, data}, message}
      end
    end

    defp validate_name_header(conn, %{"method" => method, "params" => params}) when is_map_key(@named_methods, method) do
      body_value = Map.get(params, @named_methods[method])

      case get_req_header(conn, "mcp-name") do
        [header_value] ->
          case decode_header_value(header_value) do
            {:ok, ^body_value} -> :ok
            {:ok, decoded} -> {:error, header_mismatch("mcp-name", body_value, decoded)}
            :error -> {:error, header_mismatch("mcp-name", body_value, header_value)}
          end

        values ->
          {:error, header_mismatch("mcp-name", body_value, values)}
      end
    end

    defp validate_name_header(_conn, _message), do: :ok

    defp header_matches(conn, header, body_value) do
      case get_req_header(conn, header) do
        [^body_value] -> :ok
        values -> {:error, header_mismatch(header, body_value, values)}
      end
    end

    defp header_mismatch(header, expected, actual) do
      %{header: header, expected: expected, actual: actual}
    end

    defp decode_header_value("=?base64?" <> encoded) do
      with true <- String.ends_with?(encoded, "?="),
           payload = String.slice(encoded, 0, byte_size(encoded) - 2),
           {:ok, decoded} <- Base.decode64(payload) do
        {:ok, decoded}
      else
        _ -> :error
      end
    end

    defp decode_header_value(value), do: {:ok, value}

    defp decode_request(body, protocol_module) when is_binary(body) do
      case Message.decode(body, protocol_module) do
        {:ok, [message]} when Message.is_request(message) -> {:ok, message}
        {:ok, _messages} -> {:error, :invalid_request, body}
        {:error, reason} when reason in [:parse_error, :method_not_found, :invalid_request] -> {:error, reason, body}
        {:error, _reason} -> {:error, :invalid_request, body}
      end
    end

    defp decode_request(body, protocol_module) when is_map(body) do
      case Message.validate_message(body, protocol_module) do
        {:ok, message} when Message.is_request(message) -> {:ok, message}
        {:ok, _message} -> {:error, :invalid_request, body}
        {:error, :method_not_found} -> {:error, :method_not_found, body}
        {:error, _reason} -> {:error, :invalid_request, body}
      end
    end

    defp read_request_body(%{body_params: %Unfetched{aspect: :body_params}} = conn, %{timeout: timeout}) do
      case Plug.Conn.read_body(conn, read_timeout: timeout) do
        {:ok, body, conn} -> {:ok, body, conn}
        {:error, reason} -> {:error, reason}
      end
    end

    defp read_request_body(%{body_params: body} = conn, _opts), do: {:ok, body, conn}

    defp validate_origin(conn) do
      case get_req_header(conn, "origin") do
        [] -> :ok
        [origin] -> if same_origin?(origin, conn), do: :ok, else: {:error, :invalid_origin}
        _ -> {:error, :invalid_origin}
      end
    end

    defp same_origin?(origin, conn) do
      uri = URI.parse(origin)

      uri.scheme == Atom.to_string(conn.scheme) and
        uri.host == conn.host and
        origin_port(uri) == conn.port
    end

    defp origin_port(%URI{port: port}) when is_integer(port), do: port
    defp origin_port(%URI{scheme: "http"}), do: 80
    defp origin_port(%URI{scheme: "https"}), do: 443
    defp origin_port(_uri), do: nil

    defp send_protocol_error(conn, status, error, id) do
      {:ok, response} = Error.to_json_rpc(error, id || ID.generate_error_id())

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, response)
    end

    defp extract_request_id(%{"id" => id}), do: id

    defp extract_request_id(body) when is_binary(body) do
      case JSON.decode(body) do
        {:ok, %{"id" => id}} -> id
        _ -> nil
      end
    end

    defp extract_request_id(_body), do: nil
  end
end
