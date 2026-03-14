# Recipes

Let's explore patterns we've discovered while building with Anubis MCP. What challenges are you facing?

## Authentication & Authorization

How do you ensure only authorized clients can access your server? Let's explore a few approaches:

### API Key Authentication

```elixir
defmodule MyApp.AuthenticatedServer do
  use Anubis.Server,
    name: "secure-app",
    version: "1.0.0",
    capabilities: [:tools]

  def init(arg, frame) do
    # Check API key from transport metadata
    api_key = frame.context.headers["x-api-key"]

    case authenticate_api_key(api_key) do
      {:ok, user} ->
        # Store user in frame assigns for later use
        {:ok, Map.put(frame, :assigns, %{user: user})}

      :error ->
        {:stop, :unauthorized}
    end
  end

  defp authenticate_api_key(nil), do: :error
  defp authenticate_api_key(key) do
    # Your authentication logic here
    MyApp.Auth.verify_api_key(key)
  end
end
```

Now your tools can access the authenticated user:

```elixir
defmodule MyApp.SecureTool do
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  def execute(params, frame) do
    user = frame.assigns.user

    # User-scoped operations
    {:reply, Response.text(Response.tool(), "Hello #{user.name}, you have access to this tool!"), frame}
  end
end
```

### OAuth Integration

For more complex authentication flows:

```elixir
defmodule MyApp.OAuthResource do
  use Anubis.Server.Component,
    type: :resource,
    uri: "auth://oauth/status"

  alias Anubis.Server.Response

  def read(_params, frame) do
    case frame.assigns[:oauth_token] do
      nil ->
        {:reply, Response.json(Response.resource(), %{
          authenticated: false,
          login_url: generate_oauth_url(frame.context.session_id)
        }), frame}

      token ->
        {:reply, Response.json(Response.resource(), %{
          authenticated: true,
          user: fetch_user_info(token)
        }), frame}
    end
  end
end
```

## File Operations

Need to work with files? Here's a safe pattern:

```elixir
defmodule MyApp.FileManager do
  use Anubis.Server.Component, type: :tool

  @moduledoc "Safely read files from allowed directories"

  alias Anubis.Server.Response

  schema do
    field :path, :string, required: true
  end

  def execute(%{path: path}, frame) do
    user = frame.assigns.user
    allowed_dirs = get_allowed_directories(user)

    with :ok <- validate_path_access(path, allowed_dirs),
         {:ok, content} <- File.read(path) do
      {:reply, Response.json(Response.tool(), %{
        path: path,
        size: byte_size(content),
        content: content,
        mime_type: MIME.from_path(path)
      }), frame}
    else
      {:error, :access_denied} ->
        {:reply, Response.error(Response.tool(), "Access denied to path: #{path}"), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed to read file: #{inspect(reason)}"), frame}
    end
  end

  defp validate_path_access(path, allowed_dirs) do
    real_path = Path.expand(path)

    if Enum.any?(allowed_dirs, &String.starts_with?(real_path, &1)) do
      :ok
    else
      {:error, :access_denied}
    end
  end
end
```

## Database Operations

How do you expose database queries safely?

```elixir
defmodule MyApp.QueryBuilder do
  use Anubis.Server.Component, type: :tool

  @moduledoc "Build and execute safe database queries"

  alias Anubis.Server.Response

  schema do
    field :table, :enum, required: true, values: ["users", "products", "orders"]
    field :filters, :map
    field :limit, :integer, default: 100, max: 1000
    field :order_by, :string
  end

  def execute(params, frame) do
    query =
      build_base_query(params.table)
      |> apply_filters(params[:filters])
      |> apply_order(params[:order_by])
      |> apply_limit(params.limit)
      |> apply_user_scope(frame.assigns.user)

    case MyApp.Repo.all(query) do
      results when is_list(results) ->
        {:reply, Response.json(Response.tool(), Enum.map(results, &sanitize_result/1)), frame}

      error ->
        {:reply, Response.error(Response.tool(), "Query failed: #{inspect(error)}"), frame}
    end
  end

  defp build_base_query("users"), do: from(u in User)
  defp build_base_query("products"), do: from(p in Product)
  defp build_base_query("orders"), do: from(o in Order)

  defp apply_filters(query, nil), do: query
  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn {field, value}, q ->
      where(q, [r], field(r, ^String.to_atom(field)) == ^value)
    end)
  end

  defp sanitize_result(record) do
    # Remove sensitive fields
    record
    |> Map.from_struct()
    |> Map.drop([:password_hash, :api_key, :secret_token])
  end
end
```

## Long-Running Operations

What about operations that take time? Let's handle them gracefully:

```elixir
defmodule MyApp.ReportGenerator do
  use Anubis.Server.Component, type: :tool

  @moduledoc "Generate complex reports"

  alias Anubis.Server.Response

  schema do
    field :report_type, :string, required: true
    field :date_range, :map
  end

  def execute(params, frame) do
    # Start async task
    task_id = UUID.uuid4()

    Task.start(fn ->
      result = generate_report(params)
      ReportStore.save(task_id, result)
    end)

    # Return immediately with task ID
    {:reply, Response.json(Response.tool(), %{
      task_id: task_id,
      status: "processing",
      check_status_with: "report_status"
    }), frame}
  end
end

defmodule MyApp.ReportStatus do
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :task_id, :string, required: true
  end

  def execute(%{task_id: task_id}, frame) do
    case ReportStore.get(task_id) do
      nil ->
        {:reply, Response.json(Response.tool(), %{status: "processing"}), frame}

      {:completed, result} ->
        {:reply, Response.json(Response.tool(), %{status: "completed", result: result}), frame}

      {:error, reason} ->
        {:reply, Response.json(Response.tool(), %{status: "failed", error: reason}), frame}
    end
  end
end
```

## Real-time Updates

Need to push updates to clients? Here's how:

```elixir
defmodule MyApp.LiveDataServer do
  use Anubis.Server,
    name: "live-data",
    version: "1.0.0",
    capabilities: [:tools]

  def init(arg, frame) do
    # Subscribe to Phoenix PubSub
    Phoenix.PubSub.subscribe(MyApp.PubSub, "data_updates")
    {:ok, frame}
  end

  def handle_info({:data_update, _data}, frame) do
    Anubis.Server.send_resources_list_changed()
    {:noreply, frame}
  end
end
```

## Testing Patterns

How do you test MCP components effectively?

```elixir
defmodule MyApp.ComponentTest do
  use ExUnit.Case, async: true

  describe "complex tool validation" do
    test "validates required fields" do
      tool = MyApp.ComplexTool

      # Test schema validation
      assert {:error, errors} =
        Anubis.Server.Component.validate_params(tool, %{})

      assert errors[:required_field] == ["is required"]
    end

    test "executes with valid params" do
      params = %{required_field: "value", optional_field: 42}
      frame = %Anubis.Server.Frame{assigns: %{user: %{id: 1}}}

      assert {:reply, %Anubis.Server.Response{} = response, ^frame} =
               MyApp.ComplexTool.execute(params, frame)

      assert response.type == :tool
    end
  end
end
```

## Error Recovery

How do you handle and recover from errors gracefully?

```elixir
defmodule MyApp.ResilientTool do
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  def execute(params, frame) do
    with {:ok, data} <- fetch_external_data(params),
         {:ok, processed} <- process_data(data),
         {:ok, stored} <- store_results(processed) do
      {:reply, Response.json(Response.tool(), format_success(stored)), frame}
    else
      {:error, :external_service_down} ->
        # Fallback to cache
        case get_cached_data(params) do
          {:ok, cached} ->
            {:reply, Response.json(Response.tool(), %{data: cached, source: "cache", warning: "Using cached data"}), frame}
          :error ->
            {:reply, Response.error(Response.tool(), "Service unavailable and no cached data found"), frame}
        end

      {:error, :rate_limited} ->
        {:reply, Response.error(Response.tool(), "Rate limited. Please try again in a few minutes."), frame}

      {:error, reason} ->
        Logger.error("Tool execution failed: #{inspect(reason)}")
        {:reply, Response.error(Response.tool(), "An unexpected error occurred"), frame}
    end
  end
end
```

## Performance Optimization

Need to handle high-throughput scenarios?

```elixir
defmodule MyApp.BatchProcessor do
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :items, {:list, :map}, required: true
  end

  def execute(%{items: items}, frame) do
    # Process in parallel with flow control
    results =
      items
      |> Task.async_stream(
        &process_item/1,
        max_concurrency: System.schedulers_online() * 2,
        timeout: 5_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> {:error, "Processing timeout"}
      end)

    successful = Enum.filter(results, &match?({:ok, _}, &1))
    failed = Enum.filter(results, &match?({:error, _}, &1))

    {:reply, Response.json(Response.tool(), %{
      processed: length(successful),
      failed: length(failed),
      results: successful
    }), frame}
  end
end
```

## Logging & Monitoring

How do you track what's happening in your MCP system? Let's explore logging patterns:

### MCP Protocol Logging

Control log verbosity from servers you connect to:

```elixir
# Tell the server to only send warnings and above
MyApp.Client.set_log_level("warning")

# Register a handler for incoming logs
MyApp.Client.register_log_callback(fn level, data, logger ->
  # Forward to your monitoring service
  MyApp.Telemetry.log_event(level, data, source: logger)

  # Or filter specific loggers
  if logger == "database" do
    Logger.warning("Database: #{data}")
  end
end)
```

### Server-Side Logging

Send structured logs to connected clients:

```elixir
defmodule MyApp.LoggingServer do
  use Anubis.Server,
    name: "logging-demo",
    version: "1.0.0",
    capabilities: [:tools, :logging]

  component MyApp.SomeTool

  def handle_tool_call(name, args, frame) do
    Anubis.Server.send_log_message(:info, "Processing tool: #{name}")

    result = process_tool(name, args)

    Anubis.Server.send_log_message(:debug, "Tool completed: #{name}")
    {:reply, result, frame}
  end
end
```

### Configuring Library Logging

Control Anubis's internal logging verbosity:

```elixir
# In config/config.exs
config :anubis_mcp, :logging,
  client_events: :info,      # Client lifecycle events
  server_events: :info,      # Server request handling
  transport_events: :warning, # Connection issues
  protocol_messages: :debug   # Raw message exchanges

# Or disable completely for production
config :anubis_mcp, log: false
```

## What Pattern Do You Need?

These recipes come from real-world usage. What challenges are you facing?

- Complex authentication flows?
- Multi-step workflows?
- Integration with existing systems?
- Performance at scale?
- Logging and observability?

Each pattern can be adapted to your specific needs. The key insight? MCP handles the protocol complexity while you focus on your domain logic.

Ready to implement one of these patterns?
