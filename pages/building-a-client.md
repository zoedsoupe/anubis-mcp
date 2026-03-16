# Building a Client

Let's explore how to connect your Elixir application to MCP servers. What possibilities open up when your code can leverage AI-enhanced services?

## Starting Simple

Starting a client is straightforward — add `Anubis.Client` directly to your supervision tree:

```elixir
# In your Application.start/2
children = [
  {Anubis.Client,
   name: MyApp.WeatherClient,
   transport: {:stdio, command: "weather-server", args: []},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   protocol_version: "2025-06-18"}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The client automatically:

- Launches the weather server as a subprocess
- Negotiates capabilities
- Maintains the connection
- Handles all the protocol details

All client functions take a process name (or PID) as the first argument:

```elixir
Anubis.Client.list_tools(MyApp.WeatherClient)
Anubis.Client.call_tool(MyApp.WeatherClient, "get_weather", %{"location" => "Tokyo"})
```

## Discovering Capabilities

What can a connected server actually do? Let's find out:

```elixir
# What's this server about?
info = Anubis.Client.get_server_info(MyApp.WeatherClient)
# => %{"name" => "Weather Server", "version" => "2.0.0", ...}

# What capabilities does it offer?
caps = Anubis.Client.get_server_capabilities(MyApp.WeatherClient)
# => %{"tools" => %{"listChanged" => false}, ...}

# What tools are available?
{:ok, %{result: %{"tools" => tools}}} = Anubis.Client.list_tools(MyApp.WeatherClient)

Enum.each(tools, fn tool ->
  IO.puts("#{tool["name"]}: #{tool["description"]}")
end)
# => get_weather: Get current weather for a location
# => get_forecast: Get weather forecast
```

Notice how we're exploring the server's interface dynamically?

## Using Tools

Now for the interesting part - actually using these discovered tools:

```elixir
# Simple tool call
{:ok, %{result: weather}} =
  Anubis.Client.call_tool(MyApp.WeatherClient, "get_weather", %{
    "location" => "San Francisco"
  })

# Tool with complex parameters
{:ok, %{result: forecast}} =
  Anubis.Client.call_tool(MyApp.WeatherClient, "get_forecast", %{
    "location" => "Tokyo",
    "days" => 5,
    "units" => "metric"
  })
```

What happens if something goes wrong?

```elixir
case Anubis.Client.call_tool(MyApp.WeatherClient, "get_weather", %{"location" => ""}) do
  {:ok, %{is_error: false, result: weather}} ->
    # Success path

  {:ok, %{is_error: true, result: error}} ->
    # The tool itself reported an error
    IO.puts("Tool error: #{error["message"]}")

  {:error, error} ->
    # Protocol or connection error
    IO.puts("Connection error: #{inspect(error)}")
end
```

## Working with Resources

Some servers expose resources - think files, databases, or any readable content:

```elixir
# What resources are available?
{:ok, %{result: %{"resources" => resources}}} =
  Anubis.Client.list_resources(MyApp.WeatherClient)

# Read a specific resource
{:ok, %{result: %{"contents" => contents}}} =
  Anubis.Client.read_resource(MyApp.WeatherClient, "weather://stations/KSFO")

# Resources can have multiple content types
for content <- contents do
  case content do
    %{"text" => text} ->
      IO.puts("Text content: #{text}")

    %{"blob" => blob} ->
      IO.puts("Binary data: #{byte_size(blob)} bytes")
  end
end
```

## Transport Options

How does your client actually connect to servers? Let's explore the options:

```elixir
# Local subprocess
transport: {:stdio, command: "python", args: ["-m", "my_server"]}

# HTTP endpoint
transport: {:streamable_http, base_url: "http://localhost:8000"}

# WebSocket for real-time
transport: {:websocket, base_url: "ws://localhost:8000"}

# Server-Sent Events
transport: {:sse, base_url: "http://localhost:8000"}
```

Which transport should you choose?

- **STDIO**: Perfect for local tools and subprocess isolation
- **HTTP**: Great for remote services and web APIs
- **WebSocket**: When you need bidirectional real-time communication
- **SSE**: For servers that push updates to clients (deprecated)

## Advanced Patterns

### Multiple Client Instances

Need to connect to multiple servers? Just add multiple `Anubis.Client` entries with different names:

```elixir
children = [
  {Anubis.Client,
   name: MyApp.WeatherUS,
   transport: {:stdio, command: "weather-server", args: ["--region", "US"]},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   protocol_version: "2025-06-18"},

  {Anubis.Client,
   name: MyApp.WeatherEU,
   transport: {:stdio, command: "weather-server", args: ["--region", "EU"]},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   protocol_version: "2025-06-18"}
]

# Use specific instances by name
Anubis.Client.call_tool(MyApp.WeatherUS, "get_weather", %{location: "NYC"})
Anubis.Client.call_tool(MyApp.WeatherEU, "get_weather", %{location: "Paris"})
```

### Dynamic Client Management

For scenarios where clients are created at runtime (e.g., user-configured MCP connections), use a `DynamicSupervisor`:

```elixir
# Start a DynamicSupervisor in your application
children = [
  {DynamicSupervisor, name: MyApp.MCPSupervisor, strategy: :one_for_one}
]

# Later, start clients dynamically
def connect_to_server(user_id, server_url) do
  name = :"mcp_client_#{user_id}"

  opts = [
    name: name,
    transport: {:streamable_http, base_url: server_url},
    client_info: %{"name" => "MyApp", "version" => "1.0.0"},
    protocol_version: "2025-06-18"
  ]

  DynamicSupervisor.start_child(MyApp.MCPSupervisor, {Anubis.Client, opts})
end

# Use the dynamic client by its name or PID
Anubis.Client.list_tools(:"mcp_client_42")
```

### Using PIDs Directly

All client functions accept either a registered name or a PID. This is useful when working with dynamically started clients:

```elixir
{:ok, pid} = DynamicSupervisor.start_child(MyApp.MCPSupervisor, {Anubis.Client, opts})

# Use the PID directly
Anubis.Client.list_tools(pid)
Anubis.Client.call_tool(pid, "my_tool", %{arg: "value"})
```

### Client Capabilities

Enable features your client supports using the `capabilities` option:

```elixir
{Anubis.Client,
 name: MyApp.MCPClient,
 transport: {:stdio, command: "server"},
 client_info: %{"name" => "MyApp", "version" => "1.0.0"},
 capabilities: %{"roots" => %{}, "sampling" => %{}},
 protocol_version: "2025-06-18"}
```

You can also use the `Anubis.Client.parse_capability/2` helper to build capability maps from atom shorthand:

```elixir
capabilities =
  %{}
  |> Anubis.Client.parse_capability(:roots)
  |> Anubis.Client.parse_capability({:sampling, list_changed?: true})

# => %{"roots" => %{}, "sampling" => %{"listChanged" => true}}
```

### Handling Timeouts

Long-running operations? Adjust timeouts:

```elixir
# 5 minute timeout for slow operations
opts = [timeout: 300_000]
Anubis.Client.call_tool(MyApp.WeatherClient, "analyze_historical_data", params, opts)
```

### Progress Tracking

Need to track progress on long-running operations? Here's how:

```elixir
# Generate a unique token for this operation
progress_token = Anubis.MCP.ID.generate_progress_token()

# Option 1: Just track with a token
Anubis.Client.call_tool(MyApp.WeatherClient, "analyze_data", params,
  progress: [token: progress_token]
)

# Option 2: Receive real-time updates
callback = fn ^progress_token, progress, total ->
  percentage = if total, do: "#{progress}/#{total}", else: "#{progress}"
  IO.puts("Progress: #{percentage}")
end

Anubis.Client.call_tool(MyApp.WeatherClient, "analyze_data", params,
  progress: [token: progress_token, callback: callback]
)
```

The server sends progress notifications that your callback receives automatically.

## Graceful Shutdown

When you're done:

```elixir
Anubis.Client.close(MyApp.WeatherClient)
```

This cleanly shuts down the connection and any associated resources.

## What's Next?

Now that you understand clients, what interests you?

- Building your own server to expose functionality?
- Exploring specific recipes for common patterns?
- Understanding how to handle errors gracefully?

The client handles all the protocol complexity - you just focus on using the capabilities. What will you connect to first?
