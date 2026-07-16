# Testing

Anubis components are plain modules with pure callbacks, so most of your test suite needs no running server, no transport, and no mocks. This guide covers unit testing components, testing server callbacks, and exercising the full HTTP stack when you want an integration check.

## Testing tools

A tool's `execute/2` takes validated params and a frame, and returns a tagged tuple. Call it directly:

```elixir
defmodule MyApp.ProductSearchTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.{Frame, Response}

  test "returns matching products as json" do
    frame = %Frame{}

    assert {:reply, %Response{} = response, %Frame{}} =
             MyApp.ProductSearch.execute(%{query: "lamp", limit: 10}, frame)

    assert response.type == :tool
    refute response.isError
    assert [%{"type" => "text", "text" => text}] = response.content
    assert text =~ "lamp"
  end

  test "reports a tool error when the catalog is down" do
    frame = %Frame{}

    assert {:reply, %Response{isError: true}, %Frame{}} =
             MyApp.ProductSearch.execute(%{query: "trigger-outage", limit: 10}, frame)
  end
end
```

Two details to keep in mind. First, pass params as an atom-keyed map with defaults already filled in, since that is what the validation layer hands to `execute/2` at runtime. Second, assert on the `Response` struct fields: `content` is the list of content items, `isError` flags tool-level failures, and `structured_content` holds structured output if you set it.

When a test cares about the exact wire format instead of the struct, convert it:

```elixir
assert %{"content" => [%{"type" => "text"}], "isError" => false} =
         Response.to_protocol(response)
```

## Frames in tests

Components that read assigns get a frame built the same way the server builds one:

```elixir
alias Anubis.Server.Frame

frame = Frame.assign(%Frame{}, %{user: %{id: 1, role: :admin}})

assert {:reply, response, _frame} = MyApp.SecureTool.execute(%{}, frame)
```

For components that read request context, such as auth claims or headers, populate `frame.context`:

```elixir
frame = %Frame{context: %Anubis.Server.Context{session_id: "test-session"}}
```

## Testing schemas

The `schema` block compiles into a JSON Schema exposed through `input_schema/0`. Asserting on it pins down the contract your clients see:

```elixir
test "search schema requires a query" do
  schema = MyApp.ProductSearch.input_schema()

  assert "query" in schema["required"]
  assert schema["properties"]["limit"]["type"] == "integer"
end
```

This catches accidental schema changes in review, the same way a changeset test catches a dropped validation.

## Testing resources and prompts

The pattern is identical, only the callback differs:

```elixir
test "config resource serves the current environment" do
  assert {:reply, response, _frame} = MyApp.ConfigResource.read(%{}, %Frame{})
  assert response.contents["text"] =~ "environment"
end

test "bug report prompt renders the title" do
  params = %{title: "crash on save", severity: "high"}

  assert {:reply, response, _frame} = MyApp.BugReportPrompt.get_messages(params, %Frame{})
  assert [%{"role" => "user", "content" => content}] = response.messages
  assert content =~ "crash on save"
end
```

## Testing server callbacks

Callbacks like `init/2` and `handle_info/2` are functions on your server module and test the same way:

```elixir
test "init loads categories into assigns" do
  assert {:ok, frame} = MyApp.Server.init(%{"name" => "test-client"}, %Frame{})
  assert frame.assigns.allowed_categories != []
end
```

## Integration testing over HTTP

Unit tests cover your logic; an integration test proves the whole pipe, from HTTP request through validation to your component and back. Start the server in the test and drive the plug with `Plug.Test`:

```elixir
defmodule MyApp.ServerIntegrationTest do
  use ExUnit.Case

  import Plug.Conn
  import Plug.Test

  alias Anubis.Server.Transport.StreamableHTTP

  @plug_opts StreamableHTTP.Plug.init(server: MyApp.Server)

  setup do
    start_supervised!({MyApp.Server, transport: {:streamable_http, start: true}})
    :ok
  end

  defp post_mcp(body, headers \\ []) do
    conn =
      conn(:post, "/", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    headers
    |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> StreamableHTTP.Plug.call(@plug_opts)
  end

  test "initializes and calls a tool" do
    init_conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "clientInfo" => %{"name" => "test", "version" => "1.0.0"},
          "capabilities" => %{}
        }
      })

    assert init_conn.status == 200
    [session_id] = get_resp_header(init_conn, "mcp-session-id")

    post_mcp(
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
      [{"mcp-session-id", session_id}]
    )

    call_conn =
      post_mcp(
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "product_search", "arguments" => %{"query" => "lamp"}}
        },
        [{"mcp-session-id", session_id}]
      )

    assert call_conn.status == 200
    assert call_conn.resp_body =~ "lamp"
  end
end
```

The `start: true` option forces the HTTP transport to boot even though no Phoenix endpoint is serving during tests. One integration test per server is usually enough; the per-component behavior belongs in the unit tests above.

## Next steps

- [Building a Server](building-a-server.md) documents the callbacks tested here.
- [Recipes](recipes.md) includes error handling patterns worth covering in your suite.
