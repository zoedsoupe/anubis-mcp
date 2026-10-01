defmodule Anubis.Server.HandlersServerToolsTest do
  @moduledoc """
  `server_tools/2`: the surface one connection is served, decided from its frame.

  What makes it necessary is that neither of the two places a server could otherwise decide
  this can see the caller. Registration happens at compile time, and `init/2` runs once per
  session — before the request's assigns are attached, on a session restored from a store.
  """
  use ExUnit.Case, async: true

  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers
  alias Anubis.Server.Response

  defmodule PlainServer do
    @moduledoc false
    def __components__(:tool) do
      [
        %Tool{name: "read", description: "Reads a record."},
        %Tool{name: "bulk_export", description: "Exports every record at once."}
      ]
    end
  end

  defmodule TieredServer do
    @moduledoc false
    def __components__(:tool), do: PlainServer.__components__(:tool)

    def handle_tool_call(name, _params, frame) do
      {:reply, Response.text(Response.tool(), name <> " ran"), frame}
    end

    def server_tools(tools, frame) do
      case frame.assigns[:plan] do
        :enterprise ->
          tools

        _other ->
          tools
          |> Enum.reject(&(&1.name == "bulk_export"))
          |> Enum.map(&%{&1 | description: "Reads a record. One at a time."})
      end
    end
  end

  defp list(server, frame) do
    {:reply, %{"tools" => tools}, _frame} =
      Handlers.handle(%{"method" => "tools/list"}, server, frame)

    tools
  end

  defp call(server, frame, name) do
    Handlers.handle(
      %{"method" => "tools/call", "params" => %{"name" => name, "arguments" => %{}}},
      server,
      frame
    )
  end

  describe "a server that does not export it" do
    test "is served its registered tools, unchanged" do
      assert ["bulk_export", "read"] =
               PlainServer |> list(Frame.new()) |> Enum.map(& &1.name) |> Enum.sort()
    end
  end

  describe "a server that does export it" do
    test "the frame decides which tools the connection lists" do
      enterprise = Frame.new(%{plan: :enterprise})
      free = Frame.new(%{plan: :free})

      assert "bulk_export" in Enum.map(list(TieredServer, enterprise), & &1.name)
      refute "bulk_export" in Enum.map(list(TieredServer, free), & &1.name)
    end

    test "a tool withheld from a connection cannot be called by name either" do
      # The same list answers `tools/call`'s lookup, so withholding is not merely cosmetic —
      # which is the whole reason the hook belongs here and not in `handle_list`.
      assert {:error, %{reason: :invalid_params} = error, _frame} =
               call(TieredServer, Frame.new(%{plan: :free}), "bulk_export")

      assert error.data.message =~ "Tool not found: bulk_export"

      # …and the same name still resolves for a connection that may have it, which is what
      # makes the refusal above a decision about the caller rather than about the tool.
      assert {:reply, %{"content" => [%{"text" => "bulk_export ran"}]}, _frame} =
               call(TieredServer, Frame.new(%{plan: :enterprise}), "bulk_export")
    end

    test "a tool may be returned rewritten rather than withheld" do
      [read] = list(TieredServer, Frame.new(%{plan: :free}))

      assert read.description == "Reads a record. One at a time."

      assert [%{description: "Reads a record."}, _] =
               TieredServer
               |> list(Frame.new(%{plan: :enterprise}))
               |> Enum.sort_by(& &1.name, :desc)
    end
  end
end
