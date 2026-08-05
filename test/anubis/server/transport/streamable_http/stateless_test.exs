defmodule Anubis.Server.Transport.StreamableHTTP.StatelessTest do
  use Anubis.MCP.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Anubis.Server.Registry
  alias Anubis.Server.Supervisor, as: ServerSupervisor
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  defmodule StatelessServer do
    @moduledoc false

    use Anubis.Server,
      name: "Stateless Test Server",
      version: "2.0.0",
      capabilities: [:tools, :resources],
      protocol_versions: ["2026-07-28"],
      instructions: "Discover a version before sending operational requests."
  end

  setup do
    transport_name = Registry.transport_name(StatelessServer, StubTransport)

    session_config = %{
      server_module: StatelessServer,
      registry_mod: Registry.None,
      transport: [layer: StubTransport, name: transport_name],
      session_idle_timeout: nil,
      timeout: 30_000,
      task_supervisor: Registry.task_supervisor_name(StatelessServer)
    }

    :persistent_term.put({ServerSupervisor, StatelessServer, :session_config}, session_config)

    on_exit(fn ->
      :persistent_term.erase({ServerSupervisor, StatelessServer, :session_config})
    end)

    %{opts: StreamableHTTPPlug.init(server: StatelessServer)}
  end

  describe "2026-07-28 stateless endpoint" do
    test "given a discovery request, when posted, then it returns server metadata without a session", %{opts: opts} do
      conn = stateless_request(opts, "server/discover")

      assert conn.status == 200
      assert get_resp_header(conn, "mcp-session-id") == []

      assert %{
               "id" => "stateless-request",
               "result" => %{
                 "resultType" => "complete",
                 "supportedVersions" => ["2026-07-28"],
                 "capabilities" => %{"resources" => %{}, "tools" => %{}},
                 "instructions" => "Discover a version before sending operational requests.",
                 "_meta" => %{
                   "io.modelcontextprotocol/serverInfo" => %{
                     "name" => "Stateless Test Server",
                     "version" => "2.0.0"
                   }
                 }
               }
             } = JSON.decode!(conn.resp_body)
    end

    test "given legacy session headers, when discovery is posted, then they are ignored", %{opts: opts} do
      conn =
        stateless_request(opts, "server/discover",
          extra_headers: [{"mcp-session-id", "legacy-session"}, {"last-event-id", "event-42"}]
        )

      assert conn.status == 200
      assert get_resp_header(conn, "mcp-session-id") == []
    end

    test "given a missing method header, when discovery is posted, then it returns HeaderMismatch", %{opts: opts} do
      conn = stateless_request(opts, "server/discover", include_method_header?: false)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"]["code"] == -32_020
    end

    test "given no protocol header on a stateless-only server, when posted, then it returns HeaderMismatch", %{
      opts: opts
    } do
      conn = stateless_request(opts, "server/discover", include_protocol_header?: false)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"]["code"] == -32_020
    end

    test "given mismatched protocol metadata, when discovery is posted, then it returns HeaderMismatch", %{opts: opts} do
      conn = stateless_request(opts, "server/discover", metadata_version: "2025-11-25")

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"]["code"] == -32_020
    end

    test "given an unsupported protocol version, when discovery is posted, then it returns the reserved error", %{
      opts: opts
    } do
      conn =
        stateless_request(opts, "server/discover",
          header_version: "2099-01-01",
          metadata_version: "2099-01-01"
        )

      assert conn.status == 400

      assert %{
               "code" => -32_022,
               "data" => %{
                 "requested" => "2099-01-01",
                 "supported" => ["2026-07-28"]
               }
             } = JSON.decode!(conn.resp_body)["error"]
    end

    test "given an unknown method, when posted, then it returns HTTP 404 and Method not found", %{opts: opts} do
      conn = stateless_request(opts, "unknown/method")

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body)["error"]["code"] == -32_601
    end

    test "given a named request without Mcp-Name, when posted, then it returns HeaderMismatch", %{opts: opts} do
      conn =
        stateless_request(opts, "tools/call",
          params: %{"name" => "echo", "arguments" => %{}},
          include_name_header?: false
        )

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"]["code"] == -32_020
    end

    test "given a Base64-encoded Mcp-Name, when it matches the body, then header validation succeeds", %{opts: opts} do
      name = "echo 世界"
      encoded_name = "=?base64?#{Base.encode64(name)}?="

      conn =
        stateless_request(opts, "tools/call",
          params: %{"name" => name, "arguments" => %{}},
          name_header: encoded_name
        )

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body)["error"]["code"] == -32_601
    end

    test "given an invalid Origin, when discovery is posted, then it is forbidden", %{opts: opts} do
      conn = stateless_request(opts, "server/discover", origin: "https://attacker.example")

      assert conn.status == 403
    end

    test "given a same-origin Origin, when discovery is posted, then it is accepted", %{opts: opts} do
      conn = stateless_request(opts, "server/discover", origin: "http://www.example.com")

      assert conn.status == 200
    end

    test "given a non-POST request, when sent to the stateless endpoint, then it is rejected", %{opts: opts} do
      for method <- [:get, :delete, :put] do
        conn =
          method
          |> conn("/")
          |> put_req_header("mcp-protocol-version", "2026-07-28")
          |> StreamableHTTPPlug.call(opts)

        assert conn.status == 405
      end
    end

    test "given malformed JSON, when posted, then it returns Parse error", %{opts: opts} do
      conn = raw_stateless_request(opts, "not-json", "server/discover")

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"]["code"] == -32_700
    end

    test "given an Accept lookalike, when discovery is posted, then content negotiation rejects it", %{opts: opts} do
      conn = stateless_request(opts, "server/discover", accept: "application/json-patch+json, text/event-stream")

      assert conn.status == 406
    end

    test "given a notification body, when posted, then it is rejected without crashing", %{opts: opts} do
      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/cancelled",
          "params" => %{
            "requestId" => "cancelled-request",
            "_meta" => request_meta("2026-07-28")
          }
        })

      conn = raw_stateless_request(opts, body, "notifications/cancelled")

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"]["code"] == -32_600
    end
  end

  defp stateless_request(opts, method, request_opts \\ []) do
    metadata_version = Keyword.get(request_opts, :metadata_version, "2026-07-28")
    header_version = Keyword.get(request_opts, :header_version, "2026-07-28")

    params =
      request_opts
      |> Keyword.get(:params, %{})
      |> Map.put("_meta", request_meta(metadata_version))

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "stateless-request",
        "method" => method,
        "params" => params
      })

    raw_stateless_request(opts, body, method,
      header_version: header_version,
      include_protocol_header?: Keyword.get(request_opts, :include_protocol_header?, true),
      include_method_header?: Keyword.get(request_opts, :include_method_header?, true),
      include_name_header?: Keyword.get(request_opts, :include_name_header?, true),
      name_header: Keyword.get(request_opts, :name_header),
      params: params,
      origin: Keyword.get(request_opts, :origin),
      accept: Keyword.get(request_opts, :accept, "application/json, text/event-stream"),
      extra_headers: Keyword.get(request_opts, :extra_headers, [])
    )
  end

  defp raw_stateless_request(opts, body, method, request_opts \\ []) do
    conn =
      :post
      |> conn("/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", Keyword.get(request_opts, :accept, "application/json, text/event-stream"))
      |> maybe_put_header(
        "mcp-protocol-version",
        Keyword.get(request_opts, :header_version, "2026-07-28"),
        Keyword.get(request_opts, :include_protocol_header?, true)
      )
      |> maybe_put_header("mcp-method", method, Keyword.get(request_opts, :include_method_header?, true))
      |> maybe_put_name_header(method, request_opts)
      |> maybe_put_header("origin", Keyword.get(request_opts, :origin), true)

    conn =
      Enum.reduce(Keyword.get(request_opts, :extra_headers, []), conn, fn {header, value}, conn ->
        put_req_header(conn, header, value)
      end)

    StreamableHTTPPlug.call(conn, opts)
  end

  defp maybe_put_name_header(conn, method, request_opts) when method in ["tools/call", "prompts/get"] do
    value = Keyword.get(request_opts, :name_header) || get_in(request_opts, [:params, "name"])
    maybe_put_header(conn, "mcp-name", value, Keyword.get(request_opts, :include_name_header?, true))
  end

  defp maybe_put_name_header(conn, "resources/read", request_opts) do
    value = Keyword.get(request_opts, :name_header) || get_in(request_opts, [:params, "uri"])
    maybe_put_header(conn, "mcp-name", value, Keyword.get(request_opts, :include_name_header?, true))
  end

  defp maybe_put_name_header(conn, _method, _request_opts), do: conn

  defp maybe_put_header(conn, _header, nil, _include?), do: conn
  defp maybe_put_header(conn, _header, _value, false), do: conn
  defp maybe_put_header(conn, header, value, true), do: put_req_header(conn, header, value)

  defp request_meta(version) do
    %{
      "io.modelcontextprotocol/protocolVersion" => version,
      "io.modelcontextprotocol/clientInfo" => %{"name" => "test-client", "version" => "1.0.0"},
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
  end
end
