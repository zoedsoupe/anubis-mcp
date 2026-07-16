# Recipes

Focused patterns for problems that show up once a server leaves the prototype stage. Each recipe stands alone.

## Per-session state from request headers

For HTTP transports, `frame.context.headers` carries the request headers of the initialize call. Use `init/2` to resolve them into assigns once, instead of on every tool call:

```elixir
defmodule MyApp.Server do
  use Anubis.Server,
    name: "my-app",
    version: "1.0.0",
    capabilities: [:tools]

  component MyApp.SecureTool

  @impl true
  def init(_client_info, frame) do
    tenant =
      frame.context.headers
      |> Map.get("x-tenant-id")
      |> MyApp.Tenants.get()

    {:ok, assign(frame, tenant: tenant)}
  end
end
```

Tools then scope their work to `frame.assigns.tenant`. For real authentication use OAuth bearer tokens, which Anubis validates for you before any callback runs; see [Authorization](authorization.md). If you need to reject unauthenticated requests outright with a simpler scheme such as a static API key, do it in front of the MCP plug, where you can still control the HTTP response:

```elixir
# lib/my_app_web/plugs/require_api_key.ex
defmodule MyAppWeb.Plugs.RequireApiKey do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with [key] <- get_req_header(conn, "x-api-key"),
         :ok <- MyApp.Auth.verify_api_key(key) do
      conn
    else
      _ -> conn |> send_resp(401, "unauthorized") |> halt()
    end
  end
end

# router
pipeline :mcp do
  plug MyAppWeb.Plugs.RequireApiKey
end

scope "/mcp" do
  pipe_through :mcp
  forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: MyApp.Server
end
```

## Safe file access

When a tool reads files on behalf of a model, constrain the reachable paths and treat the check as a trust boundary. Expand the path before comparing, so `../` traversal cannot escape:

```elixir
defmodule MyApp.FileReader do
  @moduledoc "Read files from the project's data directory"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  @allowed_root Path.expand("priv/data")

  schema do
    field :path, :string, required: true
  end

  @impl true
  def execute(%{path: path}, frame) do
    expanded = Path.expand(path, @allowed_root)

    with :ok <- validate_within_root(expanded),
         {:ok, content} <- File.read(expanded) do
      {:reply, Response.text(Response.tool(), content), frame}
    else
      {:error, :outside_root} ->
        {:reply, Response.error(Response.tool(), "path outside allowed directory"), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "read failed: #{inspect(reason)}"), frame}
    end
  end

  defp validate_within_root(path) do
    if String.starts_with?(path, @allowed_root <> "/"),
      do: :ok,
      else: {:error, :outside_root}
  end
end
```

## Constrained database queries

Never accept raw SQL or arbitrary field names from a model. Let the schema enumerate what is queryable, and keep the mapping from schema values to query fragments in your own code:

```elixir
defmodule MyApp.OrderLookup do
  @moduledoc "Look up recent orders, optionally filtered by status"

  use Anubis.Server.Component, type: :tool

  import Ecto.Query

  alias Anubis.Server.Response

  schema do
    field :status, :enum, values: ["pending", "shipped", "delivered"]
    field :limit, :integer, min: 1, max: 100, default: 20
  end

  @impl true
  def execute(params, frame) do
    orders =
      MyApp.Order
      |> maybe_by_status(params[:status])
      |> limit(^params.limit)
      |> where(tenant_id: ^frame.assigns.tenant.id)
      |> MyApp.Repo.all()
      |> Enum.map(&Map.take(&1, [:id, :status, :total_cents, :inserted_at]))

    {:reply, Response.json(Response.tool(), orders), frame}
  end

  defp maybe_by_status(query, nil), do: query
  defp maybe_by_status(query, status), do: where(query, status: ^status)
end
```

The enum bounds the filter, the `max` bounds the result size, and the explicit `Map.take/2` decides what leaves the system, so a new sensitive column never leaks by default.

## Long-running work

Tool calls are request-scoped, so work that outlives a sensible request timeout belongs in a background job. Split it into a starter tool and a status tool, and run the work under a supervisor rather than an unlinked task:

```elixir
defmodule MyApp.StartReport do
  @moduledoc "Start report generation, returns a job id to poll"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :report_type, :enum, values: ["sales", "inventory"], required: true
  end

  @impl true
  def execute(%{report_type: type}, frame) do
    job_id = Ecto.UUID.generate()

    Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
      result = MyApp.Reports.generate(type)
      MyApp.ReportStore.put(job_id, result)
    end)

    {:reply, Response.json(Response.tool(), %{job_id: job_id, status: "running"}), frame}
  end
end

defmodule MyApp.ReportStatus do
  @moduledoc "Check the status of a report job"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :job_id, :string, required: true
  end

  @impl true
  def execute(%{job_id: job_id}, frame) do
    body =
      case MyApp.ReportStore.get(job_id) do
        nil -> %{status: "running"}
        {:ok, result} -> %{status: "done", result: result}
        {:error, reason} -> %{status: "failed", error: inspect(reason)}
      end

    {:reply, Response.json(Response.tool(), body), frame}
  end
end
```

If your application already runs Oban, enqueue an Oban job instead of a task and read its state in the status tool.

## Pushing updates to clients

When server data changes, notify connected clients so they refresh their view of your resources. Subscribe to your event source in `init/2` and translate events in `handle_info/2`:

```elixir
defmodule MyApp.Server do
  use Anubis.Server,
    name: "my-app",
    version: "1.0.0",
    capabilities: [:tools, {:resources, list_changed?: true}]

  component MyApp.CatalogResource

  @impl true
  def init(_client_info, frame) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "catalog")
    {:ok, frame}
  end

  @impl true
  def handle_info({:catalog_updated, _payload}, frame) do
    Anubis.Server.send_resources_list_changed()
    {:noreply, frame}
  end
end
```

The `list_changed?: true` option is what advertises the notification to clients; without it they will not subscribe to changes.

## Graceful degradation

Tools that call external services should decide, per failure mode, what the model can do with the answer. A cached fallback with a warning is often more useful than a bare error:

```elixir
@impl true
def execute(params, frame) do
  case MyApp.Weather.fetch(params.city) do
    {:ok, weather} ->
      {:reply, Response.json(Response.tool(), weather), frame}

    {:error, :timeout} ->
      case MyApp.Weather.cached(params.city) do
        {:ok, weather} ->
          body = Map.put(weather, :warning, "live data unavailable, serving cache")
          {:reply, Response.json(Response.tool(), body), frame}

        :miss ->
          {:reply, Response.error(Response.tool(), "weather service unavailable"), frame}
      end

    {:error, :unknown_city} ->
      {:reply, Response.error(Response.tool(), "unknown city: #{params.city}"), frame}
  end
end
```

The error strings go to the model, so make them actionable: "unknown city" invites a corrected retry, where a stack trace invites nothing.

## MCP-level logging

Servers with the `:logging` capability can stream log messages to clients over the protocol itself, which is useful when the client is an agent that should see what happened:

```elixir
# server side, inside any callback
Anubis.Server.send_log_message(:info, "reindex started", %{index: "products"})
```

```elixir
# client side
Anubis.Client.set_log_level(MyApp.MCPClient, "warning")

Anubis.Client.register_log_callback(MyApp.MCPClient, fn level, data, logger ->
  MyApp.Telemetry.mcp_log(level, data, logger)
end)
```

## Tuning library logging

Anubis logs its own protocol activity through `Logger`. Adjust verbosity per event category, or switch it off:

```elixir
# config/config.exs
config :anubis_mcp, :logging,
  client_events: :info,
  server_events: :info,
  transport_events: :warning,
  protocol_messages: :debug

# disable all library logging
config :anubis_mcp, log: false
```

Unconfigured categories log at `:debug`.
