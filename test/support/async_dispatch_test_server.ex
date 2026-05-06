defmodule AsyncDispatchTestServer do
  @moduledoc """
  Test server with controllable tool timing for async dispatch tests.

  Tools:
    * `wait_signal` — sends `{:tool_running, self(), signal}` to `frame.assigns[:test_pid]`,
      then blocks on `receive {:proceed, ^signal}`. Lets tests inspect mid-flight state.
    * `increment` — reads/writes `frame.assigns[:counter]`. Verifies FIFO frame ordering.
    * `crash` — raises. Verifies async crash isolation.
    * `echo` — returns the input verbatim. Verifies session survives a previous crash.
  """

  use Anubis.Server,
    name: "Async Dispatch Test",
    version: "1.0.0",
    capabilities: [:tools]

  import Anubis.Server.Frame, only: [assign: 3]

  alias Anubis.MCP.Error
  alias Anubis.Server.Response

  @tools [
    %{
      "name" => "wait_signal",
      "description" => "wait for signal from test pid",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"signal" => %{"type" => "string"}},
        "required" => ["signal"]
      }
    },
    %{
      "name" => "increment",
      "description" => "increment frame counter",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "crash",
      "description" => "raise an exception",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "echo",
      "description" => "echo a string value",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}},
        "required" => ["value"]
      }
    },
    %{
      "name" => "malformed_return",
      "description" => "returns an invalid handler tuple",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  @impl true
  def handle_request(%{"method" => "ping"}, frame), do: {:reply, %{}, frame}

  def handle_request(%{"method" => "tools/list"}, frame) do
    {:reply, %{"tools" => @tools, "nextCursor" => nil}, frame}
  end

  def handle_request(%{"method" => "tools/call", "params" => params}, frame) do
    handle_tool(params["name"], params["arguments"] || %{}, frame)
  end

  def handle_request(_request, frame) do
    {:error, Error.protocol(:method_not_found), frame}
  end

  @impl true
  def handle_notification(_, frame), do: {:noreply, frame}

  @impl true
  def handle_sampling(result, request_id, frame) do
    if pid = frame.assigns[:test_pid] do
      send(pid, {:sampling_handled, request_id, result, frame.assigns[:counter]})
    end

    frame =
      frame
      |> assign(:last_sampling_result, result)
      |> assign(:last_sampling_request_id, request_id)

    {:noreply, frame}
  end

  defp handle_tool("wait_signal", %{"signal" => sig_str}, frame) do
    sig = String.to_atom(sig_str)
    if pid = frame.assigns[:test_pid], do: send(pid, {:tool_running, self(), sig})

    receive do
      {:proceed, ^sig} -> :ok
    after
      5_000 -> :ok
    end

    Response.tool()
    |> Response.text("done #{sig_str}")
    |> Response.to_protocol()
    |> then(&{:reply, &1, frame})
  end

  defp handle_tool("increment", _args, frame) do
    counter = (frame.assigns[:counter] || 0) + 1
    frame = assign(frame, :counter, counter)

    Response.tool()
    |> Response.text("count=#{counter}")
    |> Response.to_protocol()
    |> then(&{:reply, &1, frame})
  end

  defp handle_tool("crash", _args, _frame) do
    raise "intentional crash from AsyncDispatchTestServer"
  end

  defp handle_tool("malformed_return", _args, _frame) do
    :not_a_valid_handler_return
  end

  defp handle_tool("echo", %{"value" => value}, frame) do
    Response.tool()
    |> Response.text(value)
    |> Response.to_protocol()
    |> then(&{:reply, &1, frame})
  end

  defp handle_tool(name, _args, frame) do
    {:error, Error.protocol(:invalid_params, %{message: "unknown tool: #{name}"}), frame}
  end
end
