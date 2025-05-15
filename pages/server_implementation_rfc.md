# RFC: Hermes MCP Server Implementation

## Introduction

This RFC proposes a server-side implementation for the Model Context Protocol (MCP) within the Hermes MCP library. Currently, Hermes MCP provides client-side functionality, and this proposal aims to extend the library with a robust, OTP-compliant server implementation that follows Elixir best practices.

## Background

The Model Context Protocol (MCP) enables seamless integration between Language Model (LLM) applications and external data sources and tools. A complete MCP implementation requires both client and server components. The Hermes MCP library currently implements the client side, supporting various transports (STDIO, HTTP/SSE, Streamable HTTP) and providing robust message handling, logging, and telemetry.

## Goals and Requirements

The server implementation should:

1. Fully comply with the MCP specification (version 2025-03-26 AND 2024-11-05)
2. Maintain backward compatibility with older protocol versions
3. Follow OTP principles for robust, fault-tolerant operation and distribution
4. Integrate with existing Hermes components (telemetry, logging, transport, JSON-RPC encoding/decoding)
5. Support multiple transports (STDIO, HTTP/SSE, Stremable HTTP)
6. Provide both low-level and high-level APIs for server implementation
7. Support session management and distribution via Erlang clustering
8. Handle authentication (particularly OAuth 2.1 for HTTP transports)
9. Include proper error handling and logging

## Non-Goals

The implementation will not:

1. Define a complex DSL for server definition (relying instead on decorators and behaviors)
2. Aim for 100% feature parity with non-Elixir implementations
3. Support non-standard transports or protocol extensions

## Detailed Design

### Core Architecture

The server implementation will follow a layered architecture:

1. **Transport Layer**: Handles communication protocols (STDIO, HTTP/SSE)
2. **Protocol Layer**: Processes JSON-RPC messages according to MCP specification
3. **Server Layer**: Implements the core server behavior and state management
4. **Component Layer**: Implements MCP primitives (tools, resources, prompts)

### Module Structure

```
lib/hermes/server/
├── supervisor.ex            # Application and supervision
├── base.ex                  # Base server implementation 
├── behaviour.ex             # Core behavior definitions
├── server.ex                # High-level server implementation
├── registry.ex              # Session and server registry
├── decorator.ex             # Component decorators
├── component/               # Component behaviors
│   ├── tool.ex              # Tool behavior and implementation
│   ├── resource.ex          # Resource behavior and implementation
│   └── prompt.ex            # Prompt behavior and implementation
├── session/                 # Session management
│   ├── registry.ex          # Session tracking
│   └── state.ex             # Session state management
└── transport/               # Server-specific transport handlers
    ├── stdio.ex             # STDIO server transport
    └── sse.ex         # SSE server transport
```

### Behavior Definitions

#### Core Server Behavior

```elixir
defmodule Hermes.Server.Behaviour do
  @moduledoc """
  Defines the core behavior that all MCP servers must implement.
  """

  @type state :: term()
  @type request :: map()
  @type response :: map()
  @type notification :: map()
  @type mcp_error :: Hermes.MCP.Error.t()
  @type server_info :: %{name: String.t(), version: String.t()}

  @doc """
  Initializes the server state.
  """
  @callback init(init_arg :: term()) ::
              {:ok, state()} | {:error, reason :: term()}

  @doc """
  Handles incoming requests from clients.
  """
  @callback handle_request(request :: request(), state :: state()) ::
              {:reply, response :: response(), new_state :: state()}
              | {:noreply, new_state :: state()}
              | {:error, error :: mcp_error(), new_state :: state()}

  @doc """
  Handles incoming notifications from clients.
  """
  @callback handle_notification(notification :: notification(), state :: state()) ::
              {:noreply, new_state :: state()}
              | {:error, error :: mcp_error(), new_state :: state()}

  @doc """
  Returns server information for initialization response.
  """
  @callback server_info() :: server_info()

  @doc """
  Returns server capabilities for initialization response.
  Optional callback with default implementation.
  """
  @callback server_capabilities() :: map()

  @optional_callbacks [server_capabilities: 0]
end
```

#### Component Behaviors

```elixir
defmodule Hermes.Server.Component.Tool do
  @moduledoc """
  Defines the behavior for MCP tools.
  """

  @type params :: map()
  @type context :: map()
  @type result :: any()
  @type parameter_schema :: map()

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: [parameter_schema()]
  @callback handle(params :: params(), context :: context()) ::
              {:ok, result :: result()} | {:error, reason :: String.t()}
end

defmodule Hermes.Server.Component.Resource do
  @moduledoc """
  Defines the behavior for MCP resources.
  """

  @callback uri() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback mime_type() :: String.t()
  @callback read(params :: map(), context :: map()) ::
              {:ok, content :: binary() | String.t()} | {:error, reason :: String.t()}
end

defmodule Hermes.Server.Component.Prompt do
  @moduledoc """
  Defines the behavior for MCP prompts.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback arguments() :: [map()]
  @callback get(args :: map(), context :: map()) ::
              {:ok, messages :: [map()]} | {:error, reason :: String.t()}
end
```

### Base Server Implementation

```elixir
defmodule Hermes.Server.Base do
  @moduledoc """
  Base implementation of an MCP server.
  
  This module provides the core functionality for handling MCP messages,
  without any higher-level abstractions.
  """
  
  alias Hermes.MCP.{Message, Error, ID}
  alias Hermes.Telemetry
  
  @behaviour GenServer
  
  # Default protocol version
  @protocol_version "2025-03-26"
  
  # Server state structure
  defmodule State do
    defstruct [
      :mod,           # Server module implementing the behavior
      :transport,     # Transport module/pid
      :init_args,     # Initial arguments
      :server_info,   # Server information
      :capabilities,  # Server capabilities
      :custom_state,  # Custom state from the implementing module
      :initialized    # Whether the server has been initialized
    ]
  end
  
  def start_link(module, init_args, opts) do
    GenServer.start_link(__MODULE__, {module, init_args}, opts)
  end
  
  @impl GenServer
  def init({module, init_args}) do
    # Validate that module implements the required behavior
    unless implements_behaviour?(module, Hermes.Server.Behaviour) do
      raise ArgumentError, "Module #{inspect(module)} does not implement Hermes.Server.Behaviour"
    end
    
    # Get server info and capabilities
    server_info = module.server_info()
    capabilities = if function_exported?(module, :server_capabilities, 0) do
      module.server_capabilities()
    else
      %{}
    end
    
    state = %State{
      mod: module,
      init_args: init_args,
      server_info: server_info,
      capabilities: capabilities,
      initialized: false
    }
    
    case module.init(init_args) do
      {:ok, custom_state} ->
        {:ok, %{state | custom_state: custom_state}}
      {:error, reason} ->
        {:stop, reason}
    end
  end
  
  @impl GenServer
  def handle_call({:message, message}, _from, state) do
    # Handle incoming messages based on type
    with {:ok, decoded} <- decode_message(message) do
      handle_decoded_message(decoded, state)
    else
      {:error, reason} ->
        # Handle invalid message
        {:reply, {:error, %Error{code: -32700, message: "Parse error", data: reason}}, state}
    end
  end
  
  @impl GenServer
  def handle_cast({:notification, notification}, state) do
    # Handle incoming notifications
    with {:ok, decoded} <- decode_message(notification) do
      handle_decoded_notification(decoded, state)
    else
      {:error, _reason} ->
        # Just ignore invalid notifications
        {:noreply, state}
    end
  end
  
  # Implementation details for message handling, decoding, etc.
  # ...
  
  defp handle_decoded_message(%{"method" => "initialize"} = request, %{initialized: false} = state) do
    # Handle initialization request
    params = request["params"] || %{}
    protocol_version = params["protocolVersion"] || @protocol_version
    
    # Build initialization response
    response = %{
      "protocolVersion" => protocol_version,
      "serverInfo" => state.server_info,
      "capabilities" => state.capabilities
    }
    
    # Update state to indicate initialization
    new_state = %{state | initialized: true}
    
    {:reply, {:ok, response}, new_state}
  end
  
  defp handle_decoded_message(request, %{initialized: true, mod: module} = state) do
    # Dispatch request to the implementing module
    case module.handle_request(request, state.custom_state) do
      {:reply, response, new_custom_state} ->
        {:reply, {:ok, response}, %{state | custom_state: new_custom_state}}
      {:noreply, new_custom_state} ->
        {:reply, :ok, %{state | custom_state: new_custom_state}}
      {:error, error, new_custom_state} ->
        {:reply, {:error, error}, %{state | custom_state: new_custom_state}}
    end
  end
  
  defp handle_decoded_message(_request, %{initialized: false} = state) do
    # Reject non-initialization requests when not initialized
    {:reply, {:error, %Error{code: -32600, message: "Server not initialized"}}, state}
  end
  
  defp handle_decoded_notification(%{"method" => "notifications/initialized"}, state) do
    # Handle initialized notification
    {:noreply, %{state | initialized: true}}
  end
  
  defp handle_decoded_notification(notification, %{initialized: true, mod: module} = state) do
    # Dispatch notification to the implementing module
    case module.handle_notification(notification, state.custom_state) do
      {:noreply, new_custom_state} ->
        {:noreply, %{state | custom_state: new_custom_state}}
      {:error, _error, new_custom_state} ->
        # We ignore errors in notifications
        {:noreply, %{state | custom_state: new_custom_state}}
    end
  end
  
  defp handle_decoded_notification(_notification, state) do
    # Ignore notifications when not initialized
    {:noreply, state}
  end
  
  defp decode_message(message) when is_binary(message) do
    Message.decode(message)
  end
  
  defp decode_message(message) when is_map(message) do
    {:ok, message}
  end
  
  defp implements_behaviour?(module, behaviour) do
    behaviours = Keyword.take(module.__info__(:attributes), [:behaviour])
    |> Keyword.values()
    |> List.flatten()
    
    Enum.member?(behaviours, behaviour)
  end
end
```

### Decorator System

```elixir
defmodule Hermes.Server.Decorator do
  @moduledoc """
  Decorators for MCP server components.
  """
  
  use Decorator.Define, [tool: 0, resource: 0, prompt: 0]
  
  @doc """
  Marks a function as an MCP tool.
  
  The function will be registered as a tool when the server is initialized.
  The function must have a @spec defining its parameter and return types,
  which will be used to generate the tool's schema.
  
  ## Example
  
      @decorate tool()
      @spec calculate(operation :: String.t(), x :: number(), y :: number()) :: number()
      def calculate(operation, x, y) do
        case operation do
          "add" -> x + y
          "subtract" -> x - y
          "multiply" -> x * y
          "divide" when y != 0 -> x / y
          "divide" -> raise "Cannot divide by zero"
        end
      end
  """
  def tool(body, context) do
    Module.put_attribute(context.module, :mcp_tools, {context.name, context.arity})
    body
  end
  
  @doc """
  Marks a function as an MCP resource.
  
  The function will be registered as a resource when the server is initialized.
  
  ## Example
  
      @decorate resource()
      @spec readme() :: {:ok, String.t()} | {:error, String.t()}
      def readme do
        case File.read("README.md") do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, "Failed to read README: #{reason}"}
        end
      end
  """
  def resource(body, context) do
    Module.put_attribute(context.module, :mcp_resources, {context.name, context.arity})
    body
  end
  
  @doc """
  Marks a function as an MCP prompt.
  
  The function will be registered as a prompt when the server is initialized.
  
  ## Example
  
      @decorate prompt()
      @spec greeting(name :: String.t()) :: [map()]
      def greeting(name \\ nil) do
        greeting = if name, do: "Hello, #{name}!", else: "Hello!"
        
        [
          %{
            role: "assistant",
            content: %{
              type: "text",
              text: greeting
            }
          }
        ]
      end
  """
  def prompt(body, context) do
    Module.put_attribute(context.module, :mcp_prompts, {context.name, context.arity})
    body
  end
end
```

### High-Level Server Implementation

```elixir
defmodule Hermes.Server do
  @moduledoc """
  High-level MCP server implementation with decorator support.
  
  This module extends the base server with support for decorators
  and automatic handling of common requests.
  """
  
  @doc """
  Creates a new MCP server module.
  
  ## Options
  
  - `:name` - Server name (default: "Hermes MCP Server")
  - `:version` - Server version (default: "1.0.0")
  """
  defmacro __using__(opts) do
    server_name = Keyword.get(opts, :name, "Hermes MCP Server")
    server_version = Keyword.get(opts, :version, "1.0.0")
    
    quote do
      @behaviour Hermes.Server.Behaviour
      use Decorator, decorators: [Hermes.Server.Decorator]
      
      Module.register_attribute(__MODULE__, :mcp_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_resources, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_prompts, accumulate: true)
      
      @before_compile Hermes.Server
      
      @impl Hermes.Server.Behaviour
      def server_info do
        %{
          name: unquote(server_name),
          version: unquote(server_version)
        }
      end
      
      @impl Hermes.Server.Behaviour
      def server_capabilities do
        %{
          "tools" => %{},
          "resources" => %{},
          "prompts" => %{}
        }
      end
      
      @impl Hermes.Server.Behaviour
      def handle_request(%{"method" => "tools/list"} = request, state) do
        tools = fetch_mcp_tools(__MODULE__)
        
        response = %{
          "tools" => tools
        }
        
        {:reply, response, state}
      end
      
      @impl Hermes.Server.Behaviour
      def handle_request(%{"method" => "resources/list"} = request, state) do
        resources = fetch_mcp_resources(__MODULE__)
        
        response = %{
          "resources" => resources
        }
        
        {:reply, response, state}
      end
      
      @impl Hermes.Server.Behaviour
      def handle_request(%{"method" => "prompts/list"} = request, state) do
        prompts = fetch_mcp_prompts(__MODULE__)
        
        response = %{
          "prompts" => prompts
        }
        
        {:reply, response, state}
      end
      
      @impl Hermes.Server.Behaviour
      def handle_request(%{"method" => "tools/call", "params" => params} = request, state) do
        tool_name = params["name"]
        arguments = params["arguments"]
        
        case call_tool(__MODULE__, tool_name, arguments, state) do
          {:ok, result, new_state} ->
            response = %{
              "content" => [
                %{
                  "type" => "text",
                  "text" => "#{inspect(result)}"
                }
              ],
              "isError" => false
            }
            
            {:reply, response, new_state}
          
          {:error, reason, new_state} ->
            response = %{
              "content" => [
                %{
                  "type" => "text",
                  "text" => "Error: #{reason}"
                }
              ],
              "isError" => true
            }
            
            {:reply, response, new_state}
        end
      end
      
      @impl Hermes.Server.Behaviour
      def handle_request(request, state) do
        # Default implementation - return error
        {:error, %Hermes.MCP.Error{
          code: -32601,
          message: "Method not found: #{request["method"]}"
        }, state}
      end
      
      @impl Hermes.Server.Behaviour
      def handle_notification(_notification, state) do
        # Default implementation - ignore notification
        {:noreply, state}
      end
      
      defoverridable [server_capabilities: 0, handle_request: 2, handle_notification: 2]
    end
  end
  
  defmacro __before_compile__(_env) do
    quote do
      # Add helper functions for introspection
      def __mcp_tools__ do
        @mcp_tools
      end
      
      def __mcp_resources__ do
        @mcp_resources
      end
      
      def __mcp_prompts__ do
        @mcp_prompts
      end
    end
  end
  
  # Helper functions for fetching and calling MCP components
  # ...
end
```

### Session Management

```elixir
defmodule Hermes.Server.Session do
  @moduledoc """
  Manages MCP server sessions.
  """
  
  use GenServer
  
  alias Hermes.MCP.ID
  
  defmodule State do
    defstruct [
      :id,               # Session ID
      :server,           # Server module or pid
      :transport,        # Transport module or pid
      :created_at,       # Creation timestamp
      :last_activity_at, # Last activity timestamp
      :client_info,      # Client information
      :capabilities      # Client capabilities
    ]
  end
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end
  
  @impl GenServer
  def init(opts) do
    server = Keyword.fetch!(opts, :server)
    transport = Keyword.fetch!(opts, :transport)
    
    state = %State{
      id: ID.generate(),
      server: server,
      transport: transport,
      created_at: DateTime.utc_now(),
      last_activity_at: DateTime.utc_now()
    }
    
    {:ok, state}
  end
  
  # Implementation details for session management
  # ...
end
```

### Transport Integration

The existing transport modules will need to be adapted for server use. There are two main approaches:

1. **Bidirectional Adaptation**: Modify existing transports to support both client and server roles
2. **Server-Specific Transports**: Create new transport modules specifically for server use

We'll implement server-specific transports to avoid modifying existing client functionality, focusing on the STDIO transport example:

```elixir
defmodule Hermes.Server.Transport.STDIO do
  @moduledoc """
  STDIO transport implementation for MCP servers.
  """
  
  use GenServer
  
  alias Hermes.MCP.{Message, Error}
  alias Hermes.Telemetry
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end
  
  @impl GenServer
  def init(opts) do
    server = Keyword.fetch!(opts, :server)
    
    # Setup IO for stdin/stdout
    :ok = :io.setopts(standard_error: true)
    Process.flag(:trap_exit, true)
    
    state = %{
      server: server,
      buffer: ""
    }
    
    # Start reading from stdin
    schedule_read()
    
    {:ok, state}
  end
  
  @impl GenServer
  def handle_info(:read_stdin, state) do
    case IO.read(:stdio, :line) do
      :eof ->
        # End of input, terminate
        {:stop, :normal, state}
      
      {:error, reason} ->
        # Error reading from stdin, terminate
        {:stop, reason, state}
      
      data when is_binary(data) ->
        # Process incoming data
        updated_buffer = state.buffer <> data
        {messages, remaining} = extract_messages(updated_buffer)
        
        # Forward complete messages to server
        Enum.each(messages, &forward_to_server(&1, state.server))
        
        # Schedule next read
        schedule_read()
        
        {:noreply, %{state | buffer: remaining}}
    end
  end
  
  @impl GenServer
  def handle_cast({:send, message}, state) do
    # Write message to stdout
    IO.write(:stdio, message)
    {:noreply, state}
  end
  
  # Private helper functions
  
  defp schedule_read do
    send(self(), :read_stdin)
  end
  
  defp extract_messages(buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [message, rest] ->
        # We have a complete message
        {remaining_messages, final_rest} = extract_messages(rest)
        {[message | remaining_messages], final_rest}
      
      [incomplete] ->
        # No complete message yet
        {[], incomplete}
    end
  end
  
  defp forward_to_server(message, server) do
    spawn fn ->
      case Message.decode(message) do
        {:ok, [decoded]} ->
          if Message.is_request(decoded) do
            GenServer.call(server, {:message, decoded})
          else
            GenServer.cast(server, {:notification, decoded})
          end
        
        {:error, reason} ->
          # Log error but don't crash
          Telemetry.execute(
            Telemetry.event_transport_error(), 
            %{}, 
            %{error: reason, message: message}
          )
      end
    end
  end
end
```

Similar implementations would be created for the HTTP/SSE/Stremable HTTP.

### Server Registration and Discovery

A registry system will track active servers and sessions:

```elixir
defmodule Hermes.Server.Registry do
  @moduledoc """
  Registry for tracking MCP servers and sessions.
  """
  
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl GenServer
  def init(_opts) do
    # Create ETS tables for tracking servers and sessions
    :ets.new(:mcp_servers, [:set, :protected, :named_table])
    :ets.new(:mcp_sessions, [:set, :protected, :named_table])
    
    {:ok, %{}}
  end
  
  @doc """
  Registers a new MCP server.
  """
  def register_server(server_pid, server_info) do
    GenServer.call(__MODULE__, {:register_server, server_pid, server_info})
  end
  
  @doc """
  Registers a new MCP session.
  """
  def register_session(session_id, session_info) do
    GenServer.call(__MODULE__, {:register_session, session_id, session_info})
  end
  
  # Implementation details for registry functions
  # ...
end
```

### Error Handling and Telemetry

Error handling and telemetry will be integrated into all components, using existing modules where possible:

```elixir
# Add server-specific telemetry events
defmodule Hermes.Telemetry do
  # Existing events...
  
  # Server events
  def event_server_init, do: [:server, :init]
  def event_server_request, do: [:server, :request]
  def event_server_response, do: [:server, :response]
  def event_server_tool_call, do: [:server, :tool_call]
  def event_server_resource_read, do: [:server, :resource_read]
  def event_server_prompt_get, do: [:server, :prompt_get]
end
```

## Integration with Existing Code

### Message Handling

We'll leverage the existing `Hermes.MCP.Message` module for message validation and encoding/decoding, possibly extending it with server-specific functions as needed:

```elixir
# Extension to Hermes.MCP.Message
defmodule Hermes.MCP.Message do
  @moduledoc """
  Server-specific message handling extensions.
  """
  
  # rest of module
  
  @doc """
  Creates a tool list response.
  """
  def create_tool_list_response(tools, cursor \\ nil) do
    response = %{
      "tools" => tools
    }
    
    if cursor do
      Map.put(response, "nextCursor", cursor)
    else
      response
    end
  end
  
  # Similar functions for other response types
  # ...
end
```

### Telemetry Integration

We'll extend the existing telemetry system with server-specific events and spans:

```elixir
# In server implementation
Telemetry.execute(
  Telemetry.event_server_request(),
  %{duration: duration},
  %{method: method, id: id}
)
```

## Server Supervision

The server supervision tree will ensure robust operation:

```elixir
defmodule Hermes.Server.Supervisor do
  @moduledoc false
  
  use Supervisor

  def start_link(_) do
    Supervisor.start_link(__MODULE__, :ok)
  end
  
  @impl true
  def init(_) do
    children = [
      Hermes.Server.Registry,
      Hermes.Server.Session.Supervisor
    ]
    
    Supervisor.init(children, strategy: :one_for_one, name: __MODULE__)
  end
end

defmodule Hermes.Server.Session.Supervisor do
  @moduledoc """
  Supervisor for MCP server sessions.
  """
  
  use DynamicSupervisor
  
  def start_link(init_args) do
    DynamicSupervisor.start_link(__MODULE__, init_args, name: __MODULE__)
  end
  
  @impl DynamicSupervisor
  def init(_init_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
  
  @doc """
  Starts a new session process.
  """
  def start_session(server, transport, opts \\ []) do
    DynamicSupervisor.start_child(__MODULE__, {Hermes.Server.Session, [
      server: server,
      transport: transport
    ] ++ opts})
  end
end
```

## Usage Examples

### Low-Level API

```elixir
defmodule MyApp.MCPServer do
  @behaviour Hermes.Server.Behaviour
  
  @impl true
  def init(_args) do
    {:ok, %{counter: 0}}
  end
  
  @impl true
  def server_info do
    %{
      name: "My MCP Server",
      version: "1.0.0"
    }
  end
  
  @impl true
  def server_capabilities do
    %{
      "tools" => %{
        "listChanged" => true
      }
    }
  end
  
  @impl true
  def handle_request(%{"method" => "tools/list"}, state) do
    response = %{
      "tools" => [
        %{
          "name" => "counter",
          "description" => "Get or increment counter",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "increment" => %{"type" => "boolean"}
            }
          }
        }
      ]
    }
    
    {:reply, response, state}
  end
  
  @impl true
  def handle_request(%{"method" => "tools/call", "params" => %{"name" => "counter", "arguments" => args}}, state) do
    increment = Map.get(args, "increment", false)
    
    {value, new_state} = if increment do
      counter = state.counter + 1
      {counter, %{state | counter: counter}}
    else
      {state.counter, state}
    end
    
    response = %{
      "content" => [
        %{
          "type" => "text",
          "text" => "Counter value: #{value}"
        }
      ],
      "isError" => false
    }
    
    {:reply, response, new_state}
  end
  
  @impl true
  def handle_request(request, state) do
    # Fallback for unhandled requests
    {:error, %Hermes.MCP.Error{
      code: -32601,
      message: "Method not implemented: #{request["method"]}"
    }, state}
  end
  
  @impl true
  def handle_notification(_notification, state) do
    # Ignore all notifications
    {:noreply, state}
  end
end

# Start the server with STDIO transport
{:ok, _pid} = Hermes.Server.Base.start_link(MyApp.MCPServer, [], [])
{:ok, _transport} = Hermes.Server.Transport.STDIO.start_link(server: server)
```

### High-Level API (with Decorators)

```elixir
defmodule MyApp.MCPServer do
  use Hermes.Server, name: "My MCP Server", version: "1.0.0"
  
  @impl true
  def init(_args) do
    {:ok, %{counter: 0}}
  end
  
  @decorate tool()
  @spec increment_counter(current :: integer()) :: integer()
  def increment_counter(current) do
    current + 1
  end
  
  @decorate tool()
  @spec get_counter() :: integer()
  def get_counter(state) do
    state.counter
  end
  
  @decorate resource()
  @spec readme() :: {:ok, String.t()} | {:error, String.t()}
  def readme do
    case File.read("README.md") do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read README: #{reason}"}
    end
  end
  
  @decorate prompt()
  @spec greeting(name :: String.t()) :: [map()]
  def greeting(name \\ nil) do
    greeting = if name, do: "Hello, #{name}!", else: "Hello!"
    
    [
      %{
        role: "assistant",
        content: %{
          type: "text",
          text: greeting
        }
      }
    ]
  end
end

# Start the server with STDIO transport
{:ok, server} = Hermes.Server.start_link(MyApp.MCPServer)
{:ok, _transport} = Hermes.Server.Transport.STDIO.start_link(server: server)
```

## Distribution Support

The server implementation will support distribution via Erlang clustering:

```elixir
# Register servers globally to support distribution
{:ok, server} = Hermes.Server.start_link(MyApp.MCPServer, [], [name: {:global, :my_mcp_server}])

# Access server from any node in the cluster
GenServer.call({:global, :my_mcp_server}, {:message, request})
```

## Authentication

For HTTP transports, we'll support OAuth 2.1 authentication as specified in the MCP spec:

```elixir
defmodule Hermes.Server.Auth.OAuth do
  @moduledoc """
  OAuth 2.1 authentication for MCP servers.
  """
  
  # Implementation details for OAuth authentication
  # ...
end
```

## Implementation Roadmap

The implementation will proceed in phases:

### Phase 1: Core Server Implementation

1. Implement `Hermes.Server.Base` module
2. Create basic server behavior
3. Adapt STDIO transport for server use
4. Implement minimal request handling
5. Add telemetry and logging integration

### Phase 2: Component System

1. Implement component behaviors (Tool, Resource, Prompt)
2. Create decorator system for component registration
3. Implement high-level server with component support
4. Add schema generation from typespecs

### Phase 3: Transport and Distribution

1. Implement HTTP/SSE server transport
2. Add session management
3. Implement registry and discovery
4. Add distribution support

### Phase 4: Advanced Features

1. Implement OAuth authentication for HTTP transports
2. Add support for newer protocol features (audio content, batch requests)
3. Optimize performance for high-load scenarios
4. Add telemetry dashboards and monitoring

## Compatibility Considerations

### Backward Compatibility

The implementation will support older protocol versions:

- Protocol version 2024-11-05
- Future protocol versions through capability negotiation

**WARNING**

We should implement the server to be compliant to the latest MCP spec (2025-03-26) and then backward compatible with the first spec version (2024-11-05)

### Client Compatibility

The server implementation will be tested with the existing Hermes MCP client to ensure compatibility.

## Testing Strategy

The implementation will include:

1. Unit tests for each component
2. Integration tests with existing client
3. Protocol compliance tests
4. Performance benchmarks
5. Distributed system tests

## Conclusion

This detailed design provides a comprehensive plan for implementing a robust, OTP-compliant MCP server within the Hermes MCP library. The implementation leverages existing components where possible while introducing new server-specific modules and behaviors.

The decorator-based approach provides a clean, maintainable way to define server components without excessive macro usage or DSLs. The layered architecture ensures separation of concerns and follows Elixir best practices.

The proposed roadmap offers an incremental approach to implementation, focusing first on core functionality before adding more advanced features.
