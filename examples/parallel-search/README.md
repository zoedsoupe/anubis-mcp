# Parallel Search client

Run web searches and fetch page excerpts through `Anubis.Client` using
[Parallel Search MCP](https://docs.parallel.ai/integrations/mcp/search-mcp).
The anonymous endpoint needs no API key and is free for exploration and light use,
with rate limits. This example uses Streamable HTTP and calls tools directly;
it does not run an LLM or an agent loop.

## Run

Install Elixir 1.18+ and Erlang/OTP 26+, then from this repository:

```sh
cd examples/parallel-search
mix deps.get
mix run run.exs search "Elixir OTP supervision trees"
mix run run.exs fetch "https://elixir-lang.org/getting-started/introduction.html"
```

Each invocation starts a Finch pool and an Anubis client, waits for the MCP
handshake, discovers the tools, prints the selected tool's result as JSON, and
stops the supervisor. Search results include source URLs and excerpts; fetch
results include page excerpts. Protocol, transport and tool failures exit with
an error rather than printing a successful result.

The client connects to `https://search.parallel.ai/mcp` with a project User-Agent
and sends no authentication header. It does not read API keys or saved credentials.
The example is independent of the other clients and library defaults.

## Test

```sh
mix test
mix format --check-formatted
```

Tests use a local HTTP server to exercise initialization, discovery and tool
calls through the real Anubis transport without consuming the public service's
rate limit.
