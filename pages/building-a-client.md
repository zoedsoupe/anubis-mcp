# Building a Client

An MCP client connects your application to a server, whether that server is written in Elixir, Python, TypeScript, or anything else. In Anubis a client is a supervised process that owns one connection, negotiates the handshake, and exposes the server's capabilities as ordinary function calls.

## Starting a client

Add `Anubis.Client` to your supervision tree:

```elixir
children = [
  {Anubis.Client,
   name: MyApp.WeatherClient,
   transport: {:stdio, command: "weather-server", args: []},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   capabilities: %{}}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Four options matter here:

- `name` registers the process, and every client function takes this name (or a PID) as its first argument.
- `transport` says how to reach the server. See [Transports](transports.md) for the full set.
- `client_info` identifies your application to the server during the handshake.
- `capabilities` declares what your client supports. An empty map is valid and common. This option is required.

The child spec starts a small supervision tree holding the client process and its transport, linked `one_for_all`, so a transport crash restarts both cleanly.

The handshake runs asynchronously after startup. If you need to block until the connection is ready, for example in a test or a script, use `await_ready/2`:

```elixir
:ok = Anubis.Client.await_ready(MyApp.WeatherClient)
```

## Discovering capabilities

Once connected you can ask the server what it offers:

```elixir
info = Anubis.Client.get_server_info(MyApp.WeatherClient)
caps = Anubis.Client.get_server_capabilities(MyApp.WeatherClient)

{:ok, %{result: %{"tools" => tools}}} = Anubis.Client.list_tools(MyApp.WeatherClient)

for tool <- tools do
  IO.puts("#{tool["name"]}: #{tool["description"]}")
end
```

`list_resources/2`, `list_prompts/2`, and `list_resource_templates/2` follow the same shape. All list functions accept a `cursor:` option for pagination when the server paginates.

## Calling tools

```elixir
{:ok, response} =
  Anubis.Client.call_tool(MyApp.WeatherClient, "get_forecast", %{
    "location" => "Tokyo",
    "days" => 5
  })
```

Requests return `{:ok, %Anubis.MCP.Response{}}` or `{:error, %Anubis.MCP.Error{}}`. The response struct carries the raw result map and an `is_error` flag, which distinguishes the two failure levels MCP defines:

```elixir
case Anubis.Client.call_tool(MyApp.WeatherClient, "get_weather", %{"location" => ""}) do
  {:ok, %{is_error: false, result: result}} ->
    handle_weather(result)

  {:ok, %{is_error: true, result: error}} ->
    Logger.warning("tool reported failure: #{inspect(error)}")

  {:error, %Anubis.MCP.Error{} = error} ->
    Logger.error("protocol or transport failure: #{inspect(error)}")
end
```

A tool-level error (`is_error: true`) means the server ran the tool and the tool failed; the payload usually explains why. A protocol error means the request itself did not complete: the server rejected it, the transport dropped, or the call timed out.

## Reading resources and prompts

```elixir
{:ok, %{result: %{"contents" => contents}}} =
  Anubis.Client.read_resource(MyApp.WeatherClient, "weather://stations/KSFO")

for content <- contents do
  case content do
    %{"text" => text} -> handle_text(text)
    %{"blob" => blob} -> handle_binary(blob)
  end
end
```

Prompts work the same way, with arguments:

```elixir
{:ok, %{result: %{"messages" => messages}}} =
  Anubis.Client.get_prompt(MyApp.WeatherClient, "storm_briefing", %{"region" => "pacific"})
```

Servers that declare resource subscriptions also support `subscribe_resource/3` and `unsubscribe_resource/3`.

## Timeouts and progress

Every request function accepts a `timeout:` option in milliseconds, defaulting to 30 seconds:

```elixir
Anubis.Client.call_tool(client, "analyze_dataset", params, timeout: to_timeout(minute: 5))
```

For long-running operations MCP defines progress notifications. Generate a token, pass it with the request, and optionally attach a callback:

```elixir
token = Anubis.MCP.ID.generate_progress_token()

callback = fn ^token, progress, total ->
  IO.puts("progress: #{progress}/#{total || "?"}")
end

Anubis.Client.call_tool(client, "analyze_dataset", params,
  progress: [token: token, callback: callback]
)
```

The callback runs each time the server reports progress for that token.

## Multiple connections

Each client owns exactly one connection, so connecting to several servers means starting several clients:

```elixir
children = [
  {Anubis.Client,
   name: MyApp.SearchClient,
   transport: {:stdio, command: "search-server", args: []},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   capabilities: %{}},
  {Anubis.Client,
   name: MyApp.FilesClient,
   transport: {:streamable_http, base_url: "http://localhost:8000"},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   capabilities: %{}}
]
```

When connections are created at runtime, for example from user-configured server URLs, start clients under a `DynamicSupervisor`:

```elixir
children = [
  {DynamicSupervisor, name: MyApp.MCPSupervisor, strategy: :one_for_one}
]

def connect(user_id, url) do
  spec =
    {Anubis.Client,
     name: {:via, Registry, {MyApp.MCPRegistry, user_id}},
     transport_name: {:via, Registry, {MyApp.MCPRegistry, {user_id, :transport}}},
     transport: {:streamable_http, base_url: url},
     client_info: %{"name" => "MyApp", "version" => "1.0.0"},
     capabilities: %{}}

  DynamicSupervisor.start_child(MyApp.MCPSupervisor, spec)
end
```

Atom names derive a transport name automatically. With `:via` names you must provide `transport_name:` yourself, as above. All client functions accept the name or the PID returned by `start_child/2`.

## Client capabilities

Some MCP features flow from server to client: sampling asks your client to run an LLM completion, roots lets the server ask which directories it may touch, and elicitation requests structured input from the user. Declare the ones you support and register a handler:

```elixir
{Anubis.Client,
 name: MyApp.MCPClient,
 transport: {:stdio, command: "server", args: []},
 client_info: %{"name" => "MyApp", "version" => "1.0.0"},
 capabilities: %{"sampling" => %{}, "roots" => %{}}}
```

```elixir
Anubis.Client.register_sampling_callback(MyApp.MCPClient, fn request ->
  {:ok, MyApp.LLM.complete(request)}
end)

Anubis.Client.add_root(MyApp.MCPClient, "file:///home/user/project", "project")
```

`Anubis.Client.parse_capability/2` builds the capability map from atom shorthand when you prefer:

```elixir
capabilities =
  Enum.reduce([:roots, {:sampling, list_changed?: true}], %{}, &Anubis.Client.parse_capability/2)
```

## Server logs

Servers with the `:logging` capability can push log messages to your client. You can set the minimum level and handle the stream:

```elixir
Anubis.Client.set_log_level(MyApp.MCPClient, "warning")

Anubis.Client.register_log_callback(MyApp.MCPClient, fn level, data, logger ->
  Logger.log(String.to_existing_atom(level), "mcp[#{logger}]: #{inspect(data)}")
end)
```

## Shutting down

```elixir
Anubis.Client.close(MyApp.MCPClient)
```

This closes the connection and stops the transport. Under a supervisor you rarely call it yourself; stopping the supervisor tree does the same work.

## Next steps

- [Transports](transports.md) details each transport option and when to pick it.
- [Building a Server](building-a-server.md) covers the other side of the connection.
- [Recipes](recipes.md) includes patterns for progress, logging, and error recovery.
