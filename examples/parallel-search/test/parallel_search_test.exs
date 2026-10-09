defmodule ParallelSearchTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  for {tool, arguments, text} <- [
        {"web_search",
         %{"objective" => "Elixir supervision", "search_queries" => ["Elixir supervision"]},
         "https://elixir-lang.org: supervision trees"},
        {"web_fetch", %{"urls" => ["https://elixir-lang.org"]}, "Elixir is a dynamic language"}
      ] do
    test "discovers and calls #{tool} anonymously through Streamable HTTP" do
      tool = unquote(tool)
      arguments = unquote(Macro.escape(arguments))
      text = unquote(text)
      bypass = Bypass.open()
      owner = self()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        assert Plug.Conn.get_req_header(conn, "user-agent") == [
                 "anubis-mcp-parallel-example/0.1.0"
               ]

        assert Plug.Conn.get_req_header(conn, "authorization") == []
        assert Plug.Conn.get_req_header(conn, "x-api-key") == []
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = JSON.decode!(body)
        send(owner, {:method, request["method"]})

        result =
          case request["method"] do
            "initialize" ->
              %{
                "protocolVersion" => request["params"]["protocolVersion"],
                "serverInfo" => %{"name" => "parallel-fixture", "version" => "1.0.0"},
                "capabilities" => %{"tools" => %{}}
              }

            "notifications/initialized" ->
              nil

            "tools/list" ->
              %{"tools" => [%{"name" => tool, "inputSchema" => %{"type" => "object"}}]}

            "tools/call" ->
              assert request["params"]["name"] == tool
              params = request["params"]["arguments"]
              assert Map.delete(params, "session_id") == arguments
              assert params["session_id"] =~ ~r/^[0-9a-f]{32}$/
              %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}
          end

        if result do
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(
            200,
            JSON.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
          )
        else
          Plug.Conn.resp(conn, 202, "")
        end
      end)

      assert {:ok, %{is_error: false, result: %{"content" => [%{"text" => ^text}]}}} =
               ParallelSearch.run(tool, arguments, "http://localhost:#{bypass.port}")

      for method <- ["initialize", "notifications/initialized", "tools/list", "tools/call"] do
        assert_received {:method, ^method}
      end

      refute Process.whereis(ParallelSearch.Client)
      refute Process.whereis(ParallelSearch.Finch)
    end
  end

  test "a failed handshake exits and cleans up its supervisor" do
    bypass = Bypass.open()

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 400, "invalid initialize request")
    end)

    assert catch_exit(ParallelSearch.run("web_search", %{}, "http://localhost:#{bypass.port}"))
    refute Process.whereis(ParallelSearch.Client)
    refute Process.whereis(ParallelSearch.Finch)
  end
end
