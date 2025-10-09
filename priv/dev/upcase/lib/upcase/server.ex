defmodule Upcase.Server do
  @moduledoc """
  A simple MCP server that upcases input text.

  ## Features

  - Tools: Text transformation (upcase, analyze)
  - Prompts: Text transformation templates
  - Resources: Static and template-based resources

  ## Resource Templates

  This server demonstrates both compile-time and runtime resource template registration:

  - `FileTemplate` - Compile-time registration via `component/1` macro
  - `environment_variables` - Runtime registration via `register_resource_template/3` in `init/2`
  """

  use Anubis.Server, capabilities: [:tools, :resources, :prompts]

  alias Anubis.Server.Response

  require Logger

  @impl true
  def server_info do
    %{"name" => "Upcase MCP Server", "version" => "1.0.0"}
  end

  @impl true
  def supported_protocol_versions do
    ["2025-03-26", "2024-10-07", "2024-05-11"]
  end

  component(Upcase.Tools.Upcase)
  component(Upcase.Tools.AnalyzeText)
  component(Upcase.Prompts.TextTransform)
  component(Upcase.Resources.Examples)
  component(Upcase.Resources.FileTemplate)

  @impl true
  def init(client_info, frame) do
    Logger.info("We had the client_info: #{inspect(client_info)}")
    # schedule_hello()

    {:ok,
     assign(frame, counter: 0)
     |> put_pagination_limit(10)
     |> register_tool("timeout",
       description: "tests the server timeout",
       input_schema: %{interval: {:required, :integer}}
     )
     |> register_resource_template("env:///{variable}",
       name: "environment_variables",
       description: "Access environment variables dynamically",
       mime_type: "text/plain"
     )}
  end

  @impl true
  def handle_info(:hello, frame) do
    schedule_hello()
    frame = assign(frame, counter: frame.assigns.counter + 1)
    IO.puts("HELLO FROM UPCASE (on #{inspect(self())})! COUNTING: #{frame.assigns.counter}")
    {:noreply, frame}
  end

  @impl true
  def handle_tool_call("timeout", %{interval: interval}, frame) do
    IO.puts("sleeping...")
    Process.sleep(interval)
    IO.puts("slept!")
    {:reply, Response.text(Response.tool(), "slept for #{interval}"), frame}
  end

  @impl true
  def handle_resource_read("env:///" <> variable, frame) do
    case System.get_env(variable) do
      nil ->
        {:error, Anubis.MCP.Error.resource(:not_found, %{variable: variable}), frame}

      value ->
        {:reply, Response.text(Response.resource(), value), frame}
    end
  end

  def handle_resource_read(_uri, frame) do
    {:error, Anubis.MCP.Error.resource(:not_found, %{}), frame}
  end

  defp schedule_hello do
    Process.send_after(self(), :hello, 1_650)
  end
end
