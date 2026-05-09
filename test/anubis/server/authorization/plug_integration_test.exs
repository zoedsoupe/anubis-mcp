defmodule Anubis.Server.Authorization.PlugIntegrationTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Anubis.Server.Authorization
  alias Anubis.Server.Registry.Local
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: SHTTPPlug

  @moduletag capture_log: true

  defmodule FakeServer do
    @moduledoc false
    use Anubis.Server,
      name: "fake-server",
      version: "1.0.0",
      capabilities: []

    def server_info, do: %{"name" => "fake-server", "version" => "1.0.0"}
    def server_capabilities, do: %{}
    def supported_protocol_versions, do: ["2025-03-26"]
    def server_instructions, do: nil
  end

  defp build_conn(method, path, headers \\ []) do
    conn =
      method
      |> Plug.Test.conn(path, nil)
      |> put_private(:plug_skip_csrf_protection, true)

    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
  end

  defp auth_config do
    Authorization.parse_config!(
      authorization_servers: ["https://auth.example.com"],
      resource: "https://api.example.com",
      realm: "mcp",
      scopes_supported: ["tools:read", "tools:write"],
      validator: {MockTokenValidator, []}
    )
  end

  describe "well-known endpoint" do
    setup do
      # Put auth config in persistent term so the plug can read it
      config = auth_config()
      :persistent_term.put({Anubis.Server.Supervisor, FakeServer, :authorization_config}, config)

      :persistent_term.put(
        {Anubis.Server.Supervisor, FakeServer, :session_config},
        %{
          registry_mod: Local,
          task_supervisor: nil
        }
      )

      on_exit(fn ->
        :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :authorization_config})
        :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :session_config})
      end)

      :ok
    end

    test "responds 200 with JSON metadata at /.well-known/oauth-protected-resource" do
      conn =
        build_conn("GET", "/.well-known/oauth-protected-resource")

      opts = SHTTPPlug.init(server: FakeServer)

      conn = SHTTPPlug.call(conn, opts)

      assert conn.status == 200
      assert conn |> get_resp_header("content-type") |> hd() =~ "application/json"

      {:ok, body} = JSON.decode(conn.resp_body)
      assert body["resource"] == "https://api.example.com"
      assert body["authorization_servers"] == ["https://auth.example.com"]
      assert body["bearer_methods_supported"] == ["header"]
    end
  end

  describe "authorization enforcement" do
    setup do
      config = auth_config()
      :persistent_term.put({Anubis.Server.Supervisor, FakeServer, :authorization_config}, config)

      :persistent_term.put(
        {Anubis.Server.Supervisor, FakeServer, :session_config},
        %{
          registry_mod: Local,
          task_supervisor: nil
        }
      )

      on_exit(fn ->
        :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :authorization_config})
        :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :session_config})
      end)

      :ok
    end

    test "returns 401 when Authorization header is missing" do
      conn = build_conn("POST", "/mcp", [{"accept", "application/json"}])

      opts = SHTTPPlug.init(server: FakeServer)
      conn = SHTTPPlug.call(conn, opts)

      assert conn.status == 401
      assert [www_auth] = get_resp_header(conn, "www-authenticate")
      assert www_auth =~ ~s(Bearer realm="mcp")
      assert www_auth =~ "resource_metadata="
    end

    test "returns 401 when token is invalid" do
      conn =
        build_conn("POST", "/mcp", [
          {"accept", "application/json"},
          {"authorization", "Bearer invalid-token"}
        ])

      opts = SHTTPPlug.init(server: FakeServer)
      conn = SHTTPPlug.call(conn, opts)

      assert conn.status == 401
    end

    test "returns 401 when token is expired" do
      conn =
        build_conn("POST", "/mcp", [
          {"accept", "application/json"},
          {"authorization", "Bearer expired-token"}
        ])

      opts = SHTTPPlug.init(server: FakeServer)
      conn = SHTTPPlug.call(conn, opts)

      assert conn.status == 401
    end
  end

  describe "no authorization configured" do
    setup do
      :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :authorization_config})

      :persistent_term.put(
        {Anubis.Server.Supervisor, FakeServer, :session_config},
        %{
          registry_mod: Anubis.Server.Registry.None,
          task_supervisor: nil
        }
      )

      :persistent_term.put(
        {Anubis.Server.Supervisor, FakeServer, :session_supervisor_mod},
        DynamicSupervisor
      )

      on_exit(fn ->
        :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :session_config})
        :persistent_term.erase({Anubis.Server.Supervisor, FakeServer, :session_supervisor_mod})
      end)

      :ok
    end

    test "returns 404 on well-known path when no auth configured" do
      conn = build_conn("GET", "/.well-known/oauth-protected-resource")
      opts = SHTTPPlug.init(server: FakeServer)
      conn = SHTTPPlug.call(conn, opts)

      assert conn.status == 404
    end
  end
end
