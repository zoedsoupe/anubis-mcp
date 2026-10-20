# Run with: mix run examples/sem_lookup.exs /absolute/path/to/checkout SYMBOL
alias Anubis.Client

[repo, query] = System.argv()
repo = Path.expand(repo)
if !File.dir?(repo), do: raise(ArgumentError, "repo must be an existing directory")

children = [
  {Client,
   name: SemExample.Client,
   client_info: %{"name" => "anubis-sem-example", "version" => "0.1.0"},
   capabilities: %{},
   transport: {:stdio, command: "sem", args: ["mcp"], cwd: repo, env: %{"SEM_REPO" => repo}}}
]

{:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

try do
  :ok = Client.await_ready(SemExample.Client)

  case Client.call_tool(
         SemExample.Client,
         "sem_find",
         %{"query" => query, "mode" => "context", "token_budget" => 1200},
         timeout: 120_000
       ) do
    {:ok, %{is_error: false, result: result}} -> IO.puts(JSON.encode!(result))
    error -> raise "Code lookup failed: #{inspect(error)}"
  end
after
  if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
end
