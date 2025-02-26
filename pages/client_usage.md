# Client Usage Guide

This guide covers the basic usage patterns for the Hermes MCP client.

## Client Lifecycle

Once properly configured in your application's supervision tree, the Hermes client automatically handles:

1. Initial connection to the server
2. Protocol version negotiation
3. Capability exchange
4. Handshake completion

## Basic Operations

### Checking Connection Status

You can check if a server is responsive with the `ping/1` function:

```elixir
case Hermes.Client.ping(MyApp.MCPClient) do
  :pong -> IO.puts("Server is responsive")
  {:error, reason} -> IO.puts("Connection error: #{inspect(reason)}")
end
```

### Retrieving Server Information

After initialization, you can access the server's capabilities and information:

```elixir
# Get server capabilities
server_capabilities = Hermes.Client.get_server_capabilities(MyApp.MCPClient)
IO.inspect(server_capabilities, label: "Server capabilities")

# Get server version information
server_info = Hermes.Client.get_server_info(MyApp.MCPClient)
IO.inspect(server_info, label: "Server info")
```

## Working with Resources

### Listing Resources

To retrieve the list of available resources from the server:

```elixir
case Hermes.Client.list_resources(MyApp.MCPClient) do
  {:ok, %{"resources" => resources}} ->
    IO.puts("Available resources:")
    Enum.each(resources, fn resource ->
      IO.puts("  - #{resource["name"]} (#{resource["uri"]})")
    end)
    
  {:error, error} ->
    IO.puts("Error listing resources: #{inspect(error)}")
end
```

### Pagination

For large resource collections, you can use pagination with cursors:

```elixir
# First page
{:ok, %{"resources" => resources, "nextCursor" => cursor}} = 
  Hermes.Client.list_resources(MyApp.MCPClient)

# Get next page if a cursor is available
if cursor do
  {:ok, %{"resources" => more_resources}} = 
    Hermes.Client.list_resources(MyApp.MCPClient, cursor: cursor)
end
```

### Reading Resources

To read the contents of a specific resource:

```elixir
case Hermes.Client.read_resource(MyApp.MCPClient, "file:///example.txt") do
  {:ok, %{"contents" => contents}} ->
    Enum.each(contents, fn content ->
      case content do
        %{"text" => text} -> IO.puts("Text content: #{text}")
        %{"blob" => blob} -> IO.puts("Binary content: #{byte_size(blob)} bytes")
      end
    end)
    
  {:error, error} ->
    IO.puts("Error reading resource: #{inspect(error)}")
end
```

## Working with Tools

### Listing Tools

To discover available tools:

```elixir
case Hermes.Client.list_tools(MyApp.MCPClient) do
  {:ok, %{"tools" => tools}} ->
    IO.puts("Available tools:")
    Enum.each(tools, fn tool ->
      IO.puts("  - #{tool["name"]}: #{tool["description"] || "No description"}")
    end)
    
  {:error, error} ->
    IO.puts("Error listing tools: #{inspect(error)}")
end
```

### Calling Tools

To invoke a tool with arguments:

```elixir
tool_name = "calculate"
tool_args = %{"expression" => "2 + 2"}

case Hermes.Client.call_tool(MyApp.MCPClient, tool_name, tool_args) do
  {:ok, %{"content" => content, "isError" => false}} ->
    IO.puts("Tool result:")
    Enum.each(content, fn item ->
      case item do
        %{"type" => "text", "text" => text} -> IO.puts("  #{text}")
        _ -> IO.puts("  #{inspect(item)}")
      end
    end)
    
  {:ok, %{"content" => content, "isError" => true}} ->
    IO.puts("Tool execution error:")
    Enum.each(content, fn item ->
      case item do
        %{"type" => "text", "text" => text} -> IO.puts("  #{text}")
        _ -> IO.puts("  #{inspect(item)}")
      end
    end)
    
  {:error, error} ->
    IO.puts("Error calling tool: #{inspect(error)}")
end
```

## Working with Prompts

### Listing Prompts

To list available prompts:

```elixir
case Hermes.Client.list_prompts(MyApp.MCPClient) do
  {:ok, %{"prompts" => prompts}} ->
    IO.puts("Available prompts:")
    Enum.each(prompts, fn prompt ->
      required_args = prompt["arguments"] 
                      |> Enum.filter(& &1["required"])
                      |> Enum.map(& &1["name"])
                      |> Enum.join(", ")
      
      IO.puts("  - #{prompt["name"]}")
      IO.puts("    Required args: #{required_args}")
    end)
    
  {:error, error} ->
    IO.puts("Error listing prompts: #{inspect(error)}")
end
```

### Getting Prompts

To retrieve a specific prompt with arguments:

```elixir
prompt_name = "code_review"
prompt_args = %{"code" => "def hello():\n    print('world')"}

case Hermes.Client.get_prompt(MyApp.MCPClient, prompt_name, prompt_args) do
  {:ok, %{"messages" => messages}} ->
    IO.puts("Prompt messages:")
    Enum.each(messages, fn message ->
      role = message["role"]
      content = case message["content"] do
        %{"type" => "text", "text" => text} -> text
        _ -> inspect(message["content"])
      end
      
      IO.puts("  #{role}: #{content}")
    end)
    
  {:error, error} ->
    IO.puts("Error getting prompt: #{inspect(error)}")
end
```

## Error Handling

Hermes follows a consistent pattern for error handling:

```elixir
case Hermes.Client.some_operation(MyApp.MCPClient, args) do
  {:ok, result} ->
    # Handle successful result
    
  {:error, %{"code" => code, "message" => message}} ->
    # Handle protocol-level error
    IO.puts("Protocol error #{code}: #{message}")
    
  {:error, {:transport_error, reason}} ->
    # Handle transport-level error
    IO.puts("Transport error: #{inspect(reason)}")
    
  {:error, other_error} ->
    # Handle other errors
    IO.puts("Unexpected error: #{inspect(other_error)}")
end
```

## Timeouts and Cancellation

You can specify custom timeouts for operations:

```elixir
# Use a custom timeout (in milliseconds)
Hermes.Client.call_tool(MyApp.MCPClient, "slow_tool", %{}, timeout: 60_000)
```

## Extended Capabilities

To extend the client's capabilities after initialization:

```elixir
# Add sampling capability
new_capabilities = %{"sampling" => %{}}
updated_capabilities = Hermes.Client.merge_capabilities(MyApp.MCPClient, new_capabilities)
```

## Graceful Shutdown

To gracefully close a client connection:

```elixir
Hermes.Client.close(MyApp.MCPClient)
```
