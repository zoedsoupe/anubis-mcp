defmodule Mix.Tasks.Anubis.Stdio.Interactive do
  @shortdoc "Test the STDIO transport implementation interactively."

  @moduledoc """
  Mix task to test the STDIO transport implementation, interactively sending commands.

  ## Options

  * `--command` / `-c` - Command to execute for the STDIO transport (default: "mcp")
  * `--args` / `-a` - Comma-separated arguments for the command (default: "run,priv/dev/echo/index.py")
  * `--env` / `-e` - Environment variable to pass (repeatable: `--env KEY=VALUE --env OTHER=VAL`)
  * `--cwd` - Working directory for the spawned process
  * `--verbose` / `-v` - Verbosity level (repeatable for more verbosity)

  ## Examples

      # Basic usage
      mix stdio.interactive -c npx -a "@modelcontextprotocol/server-everything"

      # With environment variables
      mix stdio.interactive -c my-server --env DEBUG=1 --env LOG_LEVEL=debug

      # With working directory
      mix stdio.interactive -c ./my-server --cwd /path/to/project

      # Combined
      mix stdio.interactive -c node --args "server.js" --cwd /tmp/myapp --env NODE_ENV=production
  """

  use Mix.Task

  alias Anubis.Transport.STDIO
  alias Mix.Interactive.SupervisedShell
  alias Mix.Interactive.UI

  @switches [
    command: :string,
    args: :string,
    env: :keep,
    cwd: :string,
    verbose: :count
  ]

  def run(args) do
    # Start required applications without requiring a project
    Application.ensure_all_started(:anubis_mcp)

    # Parse arguments and set log level
    {parsed, _} =
      OptionParser.parse!(args,
        strict: @switches,
        aliases: [c: :command, e: :env, v: :verbose]
      )

    verbose_count = parsed[:verbose] || 0
    log_level = get_log_level(verbose_count)
    configure_logger(log_level)

    cmd = parsed[:command] || "mcp"

    args =
      String.split(parsed[:args] || "run,priv/dev/echo/index.py", ",", trim: true)

    env =
      parsed
      |> Keyword.get_values(:env)
      |> case do
        [] ->
          nil

        pairs ->
          Map.new(pairs, fn pair ->
            [k, v] = String.split(pair, "=", parts: 2)
            {k, v}
          end)
      end

    cwd = parsed[:cwd]

    header = UI.header("ANUBIS MCP STDIO INTERACTIVE")
    IO.puts(header)

    IO.puts("#{UI.colors().info}Starting STDIO interaction MCP server#{UI.colors().reset}\n")

    if cmd == "mcp" and not (!!System.find_executable("mcp")) do
      IO.puts(
        "#{UI.colors().error}Error: mcp executable not found in PATH, maybe you need to activate venv#{UI.colors().reset}"
      )

      System.halt(1)
    end

    SupervisedShell.start(
      transport_module: STDIO,
      transport_opts: [
        name: STDIO,
        command: cmd,
        args: args,
        env: env,
        cwd: cwd,
        client: :stdio_test
      ],
      client_opts: [
        name: :stdio_test,
        transport: [layer: STDIO, name: STDIO],
        client_info: %{
          "name" => "Mix.Tasks.STDIO",
          "version" => "1.0.0"
        },
        capabilities: %{
          "roots" => %{
            "listChanged" => true
          },
          "sampling" => %{}
        }
      ]
    )
  end

  # Helper functions
  defp get_log_level(count) do
    case count do
      0 -> :error
      1 -> :warning
      2 -> :info
      _ -> :debug
    end
  end

  defp configure_logger(log_level) do
    metadata = Logger.metadata()
    Logger.configure(level: log_level)
    Logger.metadata(metadata)
  end
end
