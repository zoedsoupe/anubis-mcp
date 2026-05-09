defmodule TasksStubServer do
  @moduledoc """
  Stub MCP server used by Tasks lifecycle tests.

  Declares the `:tasks` capability and exposes tools with different
  `task_support` values:

    * `wait_signal_add` — `:optional`. Sends `{:tool_running, self(), sig}` to
      `frame.assigns[:test_pid]` and blocks on `receive {:proceed, ^sig}`. Used
      to coordinate tests deterministically without `Process.sleep`.
    * `must_be_task` — `:required`. Echoes the message immediately.
    * `no_tasks` — defaults to `:forbidden`. Returns `"ok"`.
    * `always_fails` — `:optional`. Returns a `CallToolResult` with `isError: true`.
  """

  use Anubis.Server,
    name: "Tasks Stub Server",
    version: "1.0.0",
    capabilities: [
      :tools,
      {:tasks, list?: false, cancel?: true, requests: [tools: [:call]]}
    ]

  alias Anubis.Server.Component

  defmodule WaitSignalAdd do
    @moduledoc "Adds two integers after waiting for a `{:proceed, sig}` message."
    use Component, type: :tool, task_support: :optional

    alias Anubis.Server.Response

    schema do
      field(:a, {:required, :integer})
      field(:b, {:required, :integer})
      field(:signal, {:required, :string})
    end

    @impl true
    def execute(%{a: a, b: b, signal: sig_str}, frame) do
      sig = String.to_atom(sig_str)
      if pid = frame.assigns[:test_pid], do: send(pid, {:tool_running, self(), sig})

      receive do
        {:proceed, ^sig} -> :ok
      after
        5_000 -> :ok
      end

      {:reply, Response.text(Response.tool(), Integer.to_string(a + b)), frame}
    end
  end

  defmodule MustBeTask do
    @moduledoc "Mandatory task tool."
    use Component, type: :tool, task_support: :required

    alias Anubis.Server.Response

    schema do
      field(:msg, {:required, :string})
    end

    @impl true
    def execute(%{msg: msg}, frame) do
      {:reply, Response.text(Response.tool(), "echo: #{msg}"), frame}
    end
  end

  defmodule NoTasks do
    @moduledoc "Default policy — task augmentation forbidden."
    use Component, type: :tool

    alias Anubis.Server.Response

    schema do
      field(:noop, :string)
    end

    @impl true
    def execute(_params, frame) do
      {:reply, Response.text(Response.tool(), "ok"), frame}
    end
  end

  defmodule AlwaysFails do
    @moduledoc "Returns a CallToolResult with isError: true."
    use Component, type: :tool, task_support: :optional

    alias Anubis.Server.Response

    schema do
      field(:reason, :string)
    end

    @impl true
    def execute(%{reason: reason}, frame) do
      response = Response.error(Response.tool(), reason || "boom")

      {:reply, response, frame}
    end
  end

  component TasksStubServer.WaitSignalAdd
  component TasksStubServer.MustBeTask
  component TasksStubServer.NoTasks
  component TasksStubServer.AlwaysFails

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
