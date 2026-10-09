defmodule ParallelSearch do
  @moduledoc """
  Calls Parallel's anonymous Search MCP using Anubis Streamable HTTP.
  """

  alias Anubis.Client

  def run(tool, arguments, base_url \\ "https://search.parallel.ai") do
    children = [
      {Finch, name: ParallelSearch.Finch},
      {Client,
       name: ParallelSearch.Client,
       client_info: %{"name" => "anubis-mcp-parallel-example", "version" => "0.1.0"},
       capabilities: %{},
       transport:
         {:streamable_http,
          base_url: base_url,
          mcp_path: "/mcp",
          finch_name: ParallelSearch.Finch,
          headers: %{"user-agent" => "anubis-mcp-parallel-example/0.1.0"}}}
    ]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

    Process.unlink(supervisor)

    try do
      with :ok <- Client.await_ready(ParallelSearch.Client),
           {:ok, %{result: %{"tools" => tools}}} <- Client.list_tools(ParallelSearch.Client),
           true <- Enum.any?(tools, &(&1["name"] == tool)) do
        session_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        params = Map.put(arguments, "session_id", session_id)
        Client.call_tool(ParallelSearch.Client, tool, params, timeout: 60_000)
      else
        false -> {:error, :tool_not_available}
        error -> error
      end
    after
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
    end
  end

  def main(["search", query]) do
    display(run("web_search", %{"objective" => query, "search_queries" => [query]}))
  end

  def main(["fetch", url]) do
    display(run("web_fetch", %{"urls" => [url]}))
  end

  def main(_) do
    raise ArgumentError, "usage: search QUERY | fetch URL"
  end

  defp display({:ok, %{is_error: false, result: result}}) do
    IO.puts(JSON.encode!(result))
  end

  defp display(error) do
    raise "MCP request failed: #{inspect(error)}"
  end
end
