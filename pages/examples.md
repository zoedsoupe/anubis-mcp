# Examples

This page provides practical examples of using Hermes MCP in different scenarios. Each example demonstrates a specific use case or pattern to help you implement MCP in your Elixir applications.

## Basic Client Example

This example shows a complete implementation of a simple Hermes MCP client that connects to a Python MCP server.

Given an Echo Python MCP server:

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("Echo")

@mcp.resource("echo://{message}")
def echo_resource(message: str) -> str:
    """Echo a message as a resource"""
    return f"Resource echo: {message}"

@mcp.tool()
def echo_tool(message: str) -> str:
    """Echo a message as a tool"""
    return f"Tool echo: {message}"

@mcp.prompt()
def echo_prompt(message: str) -> str:
    """Create an echo prompt"""
    return f"Please process this message: {message}"

if __name__ == "__main__":
    mcp.run(transport='stdio')
```

You can check the custom Mix.Tasks that `Hermes defines` to run and interactive with this server from Elixir, that are:

- [stdio.echo](https://github.com/cloudwalk/hermes-mcp/blob/main/lib/mix/tasks/stdio.echo.ex)
- [stdio.echo.interactive](https://github.com/cloudwalk/hermes-mcp/blob/main/lib/mix/tasks/stdio.echo.interactive.ex)

## Authentication Example

This example demonstrates a custom authentication middleware for STDIO transport:

```elixir
defmodule MyApp.AuthenticatedTransport do
  @moduledoc """
  A transport middleware that adds authentication to JSON-RPC messages.
  """
  
  @behaviour Hermes.Transport.Behaviour
  
  alias Hermes.Transport.STDIO
  
  defstruct [:inner_transport, :auth_token, :client]
  
  @doc """
  Starts a new authenticated transport.
  
  ## Options
    * `:inner_transport_module` - The underlying transport module to use (required)
    * `:auth_token` - The authentication token to use (required)
    * Other options are passed to the inner transport
  """
  @impl true
  def start_link(opts) do
    client = Keyword.fetch!(opts, :client)
    auth_token = Keyword.fetch!(opts, :auth_token)
    inner_transport_module = Keyword.get(opts, :inner_transport_module, STDIO)
    
    # Remove our custom options before passing to inner transport
    inner_opts = opts
                 |> Keyword.delete(:auth_token)
                 |> Keyword.delete(:inner_transport_module)
    
    with {:ok, transport} <- inner_transport_module.start_link(inner_opts) do
      state = %__MODULE__{
        inner_transport: transport,
        auth_token: auth_token,
        client: client
      }
      
      pid = spawn_link(fn -> process_loop(state) end)
      
      # Register the process name if provided
      if name = Keyword.get(opts, :name) do
        Process.register(pid, name)
      end
      
      {:ok, pid}
    end
  end
  
  @impl true
  def send_message(pid, message) when is_pid(pid) and is_binary(message) do
    send(pid, {:send, message})
    :ok
  end
  
  @impl true
  def send_message(name, message) when is_atom(name) and is_binary(message) do
    send(name, {:send, message})
    :ok
  end
  
  # Main process loop
  defp process_loop(state) do
    receive do
      {:send, message} ->
        # Add authentication to outgoing messages
        case Jason.decode(message) do
          {:ok, decoded} ->
            authenticated = add_auth(decoded, state.auth_token)
            
            case Jason.encode(authenticated) do
              {:ok, json} ->
                Hermes.Transport.Behaviour.send_message(state.inner_transport, json <> "\n")
                
              {:error, reason} ->
                error = "Failed to encode authenticated message: #{inspect(reason)}"
                IO.puts(:stderr, error)
            end
            
          {:error, reason} ->
            error = "Failed to decode message for authentication: #{inspect(reason)}"
            IO.puts(:stderr, error)
        end
        
      {:response, data} ->
        # Forward responses directly to the client
        send(state.client, {:response, data})
        
      other ->
        IO.puts(:stderr, "AuthenticatedTransport received unknown message: #{inspect(other)}")
    end
    
    process_loop(state)
  end
  
  # Add authentication metadata to requests
  defp add_auth(%{"method" => method, "params" => params} = request, token) do
    # Skip authentication for the initialization message
    if method == "initialize" do
      request
    else
      auth_meta = %{"_meta" => %{"auth" => %{"token" => token}}}
      
      # Merge with existing params
      updated_params = Map.merge(params || %{}, auth_meta)
      %{request | "params" => updated_params}
    end
  end
  
  # Handle messages without params
  defp add_auth(%{"method" => method} = request, token) do
    if method == "initialize" do
      request
    else
      auth_meta = %{"_meta" => %{"auth" => %{"token" => token}}}
      Map.put(request, "params", auth_meta)
    end
  end
  
  # Pass through other message types unchanged
  defp add_auth(message, _token), do: message
end
```

Usage example with authenticated transport:

```elixir
# In your application's supervision tree
children = [
  # ...
  
  # Start the authenticated transport
  {MyApp.AuthenticatedTransport, [
    name: MyApp.MCPTransport,
    client: MyApp.MCPClient,
    auth_token: System.fetch_env!("MCP_AUTH_TOKEN"),
    inner_transport_module: Hermes.Transport.STDIO,
    command: "mcp",
    args: ["run", "server.py"]
  ]},
  
  # Start the MCP client using the authenticated transport
  {Hermes.Client, [
    name: MyApp.MCPClient,
    transport: MyApp.MCPTransport,
    client_info: %{
      "name" => "MyAuthenticatedApp",
      "version" => "1.0.0"
    },
    capabilities: %{
      "resources" => %{},
      "tools" => %{},
      "prompts" => %{}
    }
  ]},
  
  # ...
]
```

## Resource Abstraction Example

This example demonstrates a higher-level abstraction over MCP resources:

```elixir
defmodule MyApp.Resource do
  @moduledoc """
  A high-level abstraction for working with MCP resources.
  """
  
  alias Hermes.Client
  
  @type t :: %__MODULE__{
    uri: String.t(),
    name: String.t(),
    description: String.t() | nil,
    mime_type: String.t() | nil,
    size: integer() | nil,
    client: pid() | atom()
  }
  
  defstruct [:uri, :name, :description, :mime_type, :size, :client]
  
  @doc """
  Lists all available resources from the MCP server.
  """
  @spec list(pid() | atom()) :: {:ok, [t()]} | {:error, term()}
  def list(client) do
    case Client.list_resources(client) do
      {:ok, %{"resources" => resources}} ->
        resources = Enum.map(resources, fn resource ->
          %__MODULE__{
            uri: resource["uri"],
            name: resource["name"],
            description: resource["description"],
            mime_type: resource["mimeType"],
            size: resource["size"],
            client: client
          }
        end)
        
        {:ok, resources}
        
      error ->
        error
    end
  end
  
  @doc """
  Reads the content of a resource.
  
  Returns the content as text if possible, otherwise as binary.
  """
  @spec read(t() | String.t(), pid() | atom()) :: {:ok, String.t() | binary()} | {:error, term()}
  def read(%__MODULE__{} = resource), do: read(resource.uri, resource.client)
  def read(uri, client) when is_binary(uri) do
    case Client.read_resource(client, uri) do
      {:ok, %{"contents" => contents}} ->
        content = case contents do
          [%{"text" => text} | _] -> {:ok, text}
          [%{"blob" => blob} | _] -> {:ok, blob}
          [] -> {:error, :empty_content}
          other -> {:error, {:unexpected_content, other}}
        end
        
        content
        
      error ->
        error
    end
  end
  
  @doc """
  Creates a resource from a map of resource attributes.
  """
  @spec from_map(map(), pid() | atom()) :: t()
  def from_map(map, client) do
    %__MODULE__{
      uri: map["uri"],
      name: map["name"],
      description: map["description"],
      mime_type: map["mimeType"],
      size: map["size"],
      client: client
    }
  end
  
  @doc """
  Finds a resource by name.
  """
  @spec find_by_name(String.t(), pid() | atom()) :: {:ok, t()} | {:error, :not_found} | {:error, term()}
  def find_by_name(name, client) do
    with {:ok, resources} <- list(client) do
      case Enum.find(resources, fn r -> r.name == name end) do
        nil -> {:error, :not_found}
        resource -> {:ok, resource}
      end
    end
  end
  
  @doc """
  Checks if a resource is text-based or binary.
  """
  @spec text?(t()) :: boolean()
  def text?(%__MODULE__{mime_type: mime_type}) when is_binary(mime_type) do
    String.starts_with?(mime_type, "text/") or
      mime_type in ["application/json", "application/xml", "application/javascript"]
  end
  def text?(_), do: false
end
```

Usage example:

```elixir
# List all resources
{:ok, resources} = MyApp.Resource.list(MyApp.MCPClient)

# Find a specific resource by name
{:ok, config} = MyApp.Resource.find_by_name("config.json", MyApp.MCPClient)

# Read a resource's content
{:ok, content} = MyApp.Resource.read(config)

if MyApp.Resource.text?(config) do
  IO.puts("Text content: #{content}")
else
  IO.puts("Binary content: #{byte_size(content)} bytes")
end
```

These examples demonstrate different approaches to using Hermes MCP in your Elixir applications. You can adapt and extend these patterns to suit your specific needs.
