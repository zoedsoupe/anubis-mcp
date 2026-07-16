# Building a Server

An MCP server exposes parts of your application to AI clients. In Anubis a server is one module that declares identity and capabilities, plus one module per tool, resource, or prompt. This guide builds up each piece.

## The server module

```elixir
defmodule MyApp.Server do
  use Anubis.Server,
    name: "my-app",
    version: "1.0.0",
    capabilities: [:tools, :resources, :prompts]

  component MyApp.ProductSearch
  component MyApp.ConfigResource
  component MyApp.BugReportPrompt
end
```

The `name` and `version` identify your server to clients during the handshake. The `capabilities` list declares what the server offers. Available capabilities are `:tools`, `:resources`, `:prompts`, `:logging`, and `:completion`. Some accept options:

```elixir
use Anubis.Server,
  name: "my-app",
  version: "1.0.0",
  capabilities: [
    :tools,
    {:resources, subscribe?: true},
    {:prompts, list_changed?: true}
  ]
```

Each `component` line registers a module. The component name defaults to the module name converted to snake case, so `MyApp.ProductSearch` becomes `product_search`. Pass `name:` to override it:

```elixir
component MyApp.ProductSearch, name: "search"
```

Start the server under your supervision tree with a transport:

```elixir
children = [
  {MyApp.Server, transport: :stdio}
]
```

The [Transports](transports.md) guide covers STDIO, Streamable HTTP, and Phoenix integration. The rest of this guide is transport independent.

## Tools

A tool is a module that declares an input schema and implements `execute/2`:

```elixir
defmodule MyApp.ProductSearch do
  @moduledoc "Search the product catalog"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :query, :string, required: true
    field :limit, :integer, default: 10
    field :category, :string
  end

  @impl true
  def execute(%{query: query} = params, frame) do
    products =
      query
      |> MyApp.Catalog.search()
      |> maybe_filter(params[:category])
      |> Enum.take(params.limit)

    {:reply, Response.json(Response.tool(), products), frame}
  end

  defp maybe_filter(products, nil), do: products
  defp maybe_filter(products, category), do: Enum.filter(products, &(&1.category == category))
end
```

The `schema` block does double duty. It generates the JSON Schema that clients see when they list tools, and it validates incoming parameters before `execute/2` runs. Your function receives an atom-keyed map that already passed validation.

Fields support types (`:string`, `:integer`, `:number`, `:boolean`, `:enum`, `{:list, type}`), constraints (`required`, `default`, `min`, `max`, `min_length`, `max_length`, `regex`, `values`), and metadata (`description`, `format`). Nested structures use `embeds_one` and `embeds_many`:

```elixir
schema do
  field :query, :string, required: true, description: "Full text search query"
  field :sort, :enum, values: ["price", "name"], default: "name"

  embeds_one :pagination do
    field :page, :integer, min: 1, default: 1
    field :per_page, :integer, min: 1, max: 100, default: 20
  end
end
```

### Responses

Build tool responses with `Anubis.Server.Response`. Start from `Response.tool()` and pipe into content builders:

```elixir
Response.text(Response.tool(), "plain text")

Response.json(Response.tool(), %{count: 3, items: items})

Response.tool()
|> Response.structured(%{count: 3})

Response.image(Response.tool(), base64_data, "image/png")

Response.error(Response.tool(), "Query failed: timeout")
```

`Response.json/2` encodes the data and adds it as text content. `Response.structured/2` sets the `structuredContent` field defined by the protocol, which pairs with an `output_schema` block in the component if you want clients to validate your output.

`Response.error/2` produces a tool-level error, which tells the model the call failed and why. Reserve it for domain failures the model could react to. For protocol-level failures return an `Anubis.MCP.Error` instead:

```elixir
def execute(params, frame) do
  case MyApp.Catalog.search(params.query) do
    {:ok, products} ->
      {:reply, Response.json(Response.tool(), products), frame}

    {:error, :backend_down} ->
      {:error, Anubis.MCP.Error.execution("catalog backend unavailable"), frame}
  end
end
```

## Resources

Resources give clients read access to data. Each resource has a URI and implements `read/2`:

```elixir
defmodule MyApp.ConfigResource do
  @moduledoc "Current application configuration"

  use Anubis.Server.Component,
    type: :resource,
    uri: "config://app/settings",
    mime_type: "application/json"

  alias Anubis.Server.Response

  @impl true
  def read(_params, frame) do
    config = %{
      environment: Application.get_env(:my_app, :environment),
      version: to_string(Application.spec(:my_app, :vsn))
    }

    {:reply, Response.json(Response.resource(), config), frame}
  end
end
```

Clients discover resources through `resources/list` and fetch them by URI through `resources/read`. Text content goes through `Response.text/2`, binary content through `Response.blob/2`.

## Prompts

Prompts are message templates. The client fetches one with arguments, and your module returns the messages to hand to the model:

```elixir
defmodule MyApp.BugReportPrompt do
  @moduledoc "Structure a bug report from user input"

  use Anubis.Server.Component, type: :prompt

  alias Anubis.Server.Response

  schema do
    field :title, :string, required: true
    field :severity, :enum, values: ["low", "medium", "high"], default: "low"
  end

  @impl true
  def get_messages(%{title: title, severity: severity}, frame) do
    response =
      Response.prompt()
      |> Response.user_message("""
      File a bug report titled "#{title}" with severity #{severity}.
      Ask me for reproduction steps if anything is unclear.
      """)

    {:reply, response, frame}
  end
end
```

`Response.user_message/2`, `Response.assistant_message/2`, and `Response.system_message/2` append messages in order.

## Descriptions

Clients pick tools by reading their descriptions, so treat them as part of your interface. By default a component's description is its `@moduledoc`. When the description depends on runtime state, implement `description/0` instead:

```elixir
defmodule MyApp.WeatherTool do
  @moduledoc false

  use Anubis.Server.Component, type: :tool

  @impl true
  def description do
    interval = Application.get_env(:my_app, :weather_cache_minutes, 15)
    "Current weather for a city. Data refreshes every #{interval} minutes."
  end
end
```

A good description says what the component does and when to use it, in a sentence or two. Field-level `description:` options serve the same purpose for parameters.

## Server state and the frame

Every callback receives a `%Anubis.Server.Frame{}`. The frame carries two things you will use often:

- `frame.assigns` is your own state for the session, managed like assigns in a `Plug.Conn` or LiveView socket.
- `frame.context` holds request context: the session id, the client info sent during the handshake, and for HTTP transports the request headers, remote IP, and validated auth claims.

The `init/2` callback runs when a client starts the handshake and is the place to set up assigns:

```elixir
defmodule MyApp.Server do
  use Anubis.Server,
    name: "my-app",
    version: "1.0.0",
    capabilities: [:tools]

  component MyApp.ProductSearch

  @impl true
  def init(_client_info, frame) do
    {:ok, assign(frame, allowed_categories: MyApp.Catalog.categories())}
  end
end
```

Components then read and update the frame:

```elixir
def execute(params, frame) do
  categories = frame.assigns.allowed_categories
  frame = assign(frame, :last_query, params.query)

  {:reply, Response.json(Response.tool(), search(params, categories)), frame}
end
```

Each connected client gets its own session process with its own frame, so assigns are naturally isolated per session.

## Notifications

Servers can push notifications to connected clients. Call these from inside server callbacks:

```elixir
Anubis.Server.send_tools_list_changed()
Anubis.Server.send_resources_list_changed()
Anubis.Server.send_prompts_list_changed()
Anubis.Server.send_resource_updated(uri)
Anubis.Server.send_log_message(:info, "reindex finished")
```

The list-changed notifications require the matching capability option, for example `{:tools, list_changed?: true}`. A common pattern bridges application events into MCP notifications through `handle_info/2`:

```elixir
@impl true
def init(_client_info, frame) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "catalog")
  {:ok, frame}
end

@impl true
def handle_info({:catalog_updated, _}, frame) do
  Anubis.Server.send_resources_list_changed()
  {:noreply, frame}
end
```

These functions message the current session process, so they only work inside callbacks. From an external process, send to the session PID directly.

## Next steps

- [Transports](transports.md) shows how to serve this over STDIO or HTTP, including from a Phoenix app.
- [Authorization](authorization.md) adds OAuth 2.1 bearer token validation and per-component scopes.
- [Testing](testing.md) covers testing components without a running transport.
