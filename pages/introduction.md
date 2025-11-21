# Welcome to Anubis MCP

## The LiveView Moment for AI Development

What Phoenix LiveView did for real-time web experiences, Anubis MCP does for AI assistant integration. Turn your Elixir applications into AI superpowers with the same simplicity and reliability you love about the BEAM.

## The AI Integration Revolution

Your AI assistants are hungry for capabilities, but they're trapped in isolation. The Model Context Protocol (MCP) breaks down these walls, creating secure, composable bridges between AI and your applications.

Think of it this way: instead of AI assistants being isolated chatbots, they become extensions of your entire system architecture. Your Phoenix app's user management, your GenServer's real-time data processing, your OTP-supervised background jobs - all available to AI assistants through a fault-tolerant protocol.

Anubis MCP makes this vision real with Elixir's battle-tested concurrency model and Phoenix's developer happiness principles.

## Your First AI Connection

Let's connect to an existing MCP server in under three minutes:

```elixir
# In your mix.exs
{:anubis_mcp, "~> 0.16.0"} # x-release-please-version
```

Define a client that speaks MCP:

```elixir
defmodule MyApp.ClaudeClient do
  use Anubis.Client,
    name: "MyApp",
    version: "1.0.0",
    protocol_version: "2024-11-05",
    capabilities: [:roots, :sampling]
end
```

Add it to your supervision tree:

```elixir
# In your Application.start/2
children = [
  {MyApp.ClaudeClient,
   transport: {:stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-everything"]}}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Now watch the magic:

```elixir
# Discover what's available
{:ok, tools} = MyApp.ClaudeClient.list_tools()
# => Find web search, file operations, and more

# Use AI capabilities from your Elixir code
{:ok, result} = MyApp.ClaudeClient.call_tool("web_search", %{query: "elixir otp patterns"})

# Even read resources
{:ok, content} = MyApp.ClaudeClient.read_resource("file:///project/README.md")
```

Your Elixir application now has AI-powered web search, file operations, and more. All fault-tolerant, all supervised, all feeling like native Elixir.

## Exposing Your App to AI

The real power comes when AI assistants can use your application's capabilities. Here's how to expose your Elixir logic:

```elixir
defmodule MyApp.Server do
  use Anubis.Server,
    name: "my-app-server",
    version: "1.0.0",
    capabilities: [:tools]

  component MyApp.UserLookup
  component MyApp.DataProcessor
end

defmodule MyApp.UserLookup do
  @moduledoc "Find users by email or ID"

  use Anubis.Server.Component, type: :tool
  alias Anubis.Server.Response

  schema do
    field :email, :string, regex: ~r/@/, format: "email", required: true
  end

  def execute(%{email: email}, frame) when is_binary(email) do
    case MyApp.Users.get_by_email(email) do
      %User{} = user ->
        result = %{id: user.id, name: user.name, email: user.email}
        {:reply, Response.tool() |> Response.structured(result), frame}

      nil ->
        {:reply, Response.tool() |> Response.error("User not found"), frame}
    end
  end
end
```

Start your server:

```elixir
# In your supervision tree
children = [
  # Your existing app
  MyApp.Repo,
  MyAppWeb.Endpoint,

  # Your MCP server
  {MyApp.Server, transport: :stdio}
]
```

Now any AI assistant can discover and use your user lookup functionality through the MCP protocol. They'll get proper JSON schema documentation, structured responses, and error handling - all automatically generated from your Elixir code.

## Real-World Power

This is just the beginning. Anubis MCP enables:

**Fault-Tolerant AI Integration** - Process crashes don't break your AI connections. Supervision trees ensure reliability.

**Composable AI Capabilities** - Mix and match different MCP servers. One for file operations, another for database access, another for your business logic.

**Phoenix Integration** - Expose LiveView data, trigger real-time updates, authenticate users - all through AI assistants.

**OTP-Native Patterns** - GenServers become AI tools. Agents become AI resources. Your entire BEAM ecosystem becomes AI-accessible.

**Type Safety & Validation** - Peri-powered schema validation ensures AI tools receive clean, validated data.

**Progressive Enhancement** - Start simple, add capabilities incrementally. No big rewrites needed.

## Ready to Build?

The framework handles transport negotiation, capability discovery, error recovery, and request routing. You focus on what your application does best.

_Turn your Elixir applications into AI superpowers. It's time for your AI assistants to meet the BEAM._
