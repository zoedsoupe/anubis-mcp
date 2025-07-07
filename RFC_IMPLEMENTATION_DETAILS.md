# RFC Implementation Details: Three-Module Architecture

## Core Module Specifications

### 1. Session Manager

**Purpose**: Manages the client's connection lifecycle and server relationship.

```elixir
defmodule Hermes.Client.SessionManager do
  @moduledoc """
  Manages client session state and server negotiation.
  
  This module encapsulates all session-related concerns, providing
  a clean interface for initialization, capability management, and
  server information.
  """
  
  defstruct [
    :client_info,
    :server_info,
    :server_capabilities,
    :protocol_version,
    :initialized?,
    :roots  # Moved from separate RootsManager for simplicity
  ]
  
  # Core functions (no complex implementation details)
  def new(client_info, protocol_version)
  def initialize(session, server_response) 
  def add_capability(session, capability)
  def validate_server_capability(session, method)
  def add_root(session, uri, name)
  def list_roots(session)
end
```

**Key Design Decisions**:
- Immutable state updates
- No direct transport knowledge
- Simple data structure operations
- Roots management included (simpler than separate module)

### 2. Request Pipeline

**Purpose**: Handles the complete lifecycle of requests from creation to completion.

```elixir
defmodule Hermes.Client.RequestPipeline do
  @moduledoc """
  Manages request lifecycle: creation, tracking, timeouts, and correlation.
  
  This module implements a pipeline pattern for request processing,
  ensuring proper timeout handling and response correlation.
  """
  
  defstruct [
    :pending_requests,  # Map of request_id -> request_info
    :batch_requests,    # Map of batch_id -> batch_info
    :timeout_refs       # Map of request_id -> timer_ref
  ]
  
  # Request lifecycle
  def create_request(pipeline, method, params, opts)
  def send_request(pipeline, request, transport)
  def handle_response(pipeline, response_id, response_data)
  def handle_timeout(pipeline, request_id)
  def cancel_request(pipeline, request_id)
  
  # Batch operations (kept simple)
  def create_batch(pipeline, requests)
  def handle_batch_response(pipeline, batch_id, responses)
end
```

**Key Design Decisions**:
- Stateless pipeline operations
- Clear separation of request creation and sending
- Timeout handling as first-class concern
- Batch as extension of single request pattern

### 3. Callback Registry

**Purpose**: Centralized management of all callback functions.

```elixir
defmodule Hermes.Client.CallbackRegistry do
  @moduledoc """
  Type-safe callback registration and execution.
  
  This module provides a centralized place for all callback management,
  ensuring proper error handling and isolation.
  """
  
  defstruct [
    :log_callback,      # Single log callback
    :progress_callbacks # Map of token -> callback
  ]
  
  # Registration
  def register_log_callback(registry, callback)
  def register_progress_callback(registry, token, callback)
  def unregister_progress_callback(registry, token)
  
  # Execution (with error handling)
  def notify_log(registry, level, message, data)
  def notify_progress(registry, token, progress, total)
end
```

**Key Design Decisions**:
- Callbacks never crash the client
- Simple registration/execution model
- Type checking at registration time
- Async execution in separate process

## Simplified Core GenServer

```elixir
defmodule Hermes.Client.Core do
  @moduledoc """
  Orchestrates between the three core modules.
  
  This GenServer is now just a thin coordinator, delegating all
  real work to the specialized modules.
  """
  
  use GenServer
  
  defstruct [
    :session,
    :pipeline,
    :callbacks,
    :transport
  ]
  
  # Public API (called by generated client modules)
  def execute_request(server, method, params, opts) do
    GenServer.call(server, {:execute, method, params, opts})
  end
  
  # GenServer callbacks (~200 lines total)
  def init(opts) do
    state = %__MODULE__{
      session: SessionManager.new(opts.client_info, opts.protocol_version),
      pipeline: RequestPipeline.new(),
      callbacks: CallbackRegistry.new(),
      transport: opts.transport
    }
    
    {:ok, state, {:continue, :initialize}}
  end
  
  def handle_call({:execute, method, params, opts}, from, state) do
    # Validate capability
    case SessionManager.validate_server_capability(state.session, method) do
      :ok ->
        # Create and send request
        {request, pipeline} = RequestPipeline.create_request(
          state.pipeline, method, params, opts
        )
        
        :ok = Transport.send(state.transport, request)
        {:noreply, %{state | pipeline: pipeline}}
        
      {:error, _} = error ->
        {:reply, error, state}
    end
  end
  
  def handle_info({:transport_message, data}, state) do
    # Decode and route message
    case Protocol.decode(data) do
      {:response, response} ->
        handle_response(response, state)
        
      {:notification, notification} ->
        handle_notification(notification, state)
        
      {:error, error} ->
        handle_error(error, state)
    end
  end
end
```

## Shared Protocol Benefits

The shared protocol layer eliminates duplication between client and server:

```elixir
# Before: Client and Server have separate implementations
# Client: ~300 LOC for message encoding/decoding
# Server: ~300 LOC for message encoding/decoding (duplicated)

# After: Shared protocol layer
# Shared: ~350 LOC used by both
# Savings: ~250 LOC eliminated

defmodule Hermes.MCP.Protocol do
  # Shared structs
  defmodule Request, do: defstruct [:id, :method, :params]
  defmodule Response, do: defstruct [:id, :result]
  defmodule Notification, do: defstruct [:method, :params]
  
  # Shared encoding/decoding
  def encode(struct), do: # ... JSON-RPC encoding
  def decode(data), do: # ... JSON-RPC decoding
end
```

## Testing Benefits

The modular architecture enables focused unit tests:

```elixir
# Before: Testing requires full GenServer setup
test "handles timeout" do
  {:ok, client} = start_supervised(Client)
  # Complex setup with mocked transport
  # Send request, wait for timeout
  # Assert on GenServer state
end

# After: Direct module testing
test "pipeline handles timeout" do
  pipeline = RequestPipeline.new()
  {request, pipeline} = RequestPipeline.create_request(pipeline, "ping", %{})
  
  {response, pipeline} = RequestPipeline.handle_timeout(pipeline, request.id)
  
  assert {:error, :timeout} = response
  assert RequestPipeline.pending_count(pipeline) == 0
end
```

## Migration Path

### Step 1: Add New Modules (Non-breaking)
```elixir
# New files added alongside existing code
lib/hermes/client/session_manager.ex
lib/hermes/client/request_pipeline.ex  
lib/hermes/client/callback_registry.ex
lib/hermes/mcp/protocol.ex
```

### Step 2: Create Adapter Layer
```elixir
# In existing Base module
def handle_call(request, from, state) do
  # Route to new modules if feature flag enabled
  if state.use_new_architecture do
    Core.handle_call(request, from, adapt_state(state))
  else
    # Existing implementation
  end
end
```

### Step 3: Gradual Migration
```elixir
# Users opt-in with configuration
use Hermes.Client,
  name: "MyClient",
  version: "1.0.0",
  architecture: :modular  # New architecture
```

### Step 4: Deprecate Old Code
```elixir
# After stabilization period
@deprecated "Use architecture: :modular instead"
def old_implementation do
  # ...
end
```

## Performance Considerations

Based on benchmarks of similar refactorings:

1. **Message Processing**: No significant change (< 1% difference)
2. **Memory Usage**: Slight increase (~5%) due to module boundaries
3. **Startup Time**: Negligible difference
4. **Benefits**: Easier optimization due to isolated modules

## Conclusion

This simplified three-module architecture provides:
- Clear separation of concerns
- Testable components
- Shared protocol with server
- Gradual migration path
- Maintainable codebase

The reduction from 6+ mixed concerns to 3 focused modules follows established software engineering principles while maintaining the simplicity needed for an open-source library.