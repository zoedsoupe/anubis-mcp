defmodule Anubis.Server.ComponentTitleTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Component
  alias Anubis.Server.Response

  describe "Tool component title option" do
    defmodule ToolWithTitle do
      @moduledoc false

      use Component, type: :tool, title: "My Tool"

      schema do
        field :input, :string
      end

      @impl true
      def execute(_params, frame), do: {:reply, Response.tool(), frame}
    end

    defmodule ToolWithoutTitle do
      @moduledoc false

      use Component, type: :tool

      schema do
        field :input, :string
      end

      @impl true
      def execute(_params, frame), do: {:reply, Response.tool(), frame}
    end

    test "defines title/0 when the :title option is passed" do
      assert ToolWithTitle.title() == "My Tool"
    end

    test "does not export title/0 when the :title option is omitted" do
      refute function_exported?(ToolWithoutTitle, :title, 0)
    end
  end

  describe "Resource component title option" do
    defmodule ResourceWithTitle do
      @moduledoc false

      use Component,
        type: :resource,
        uri: "test://resource-with-title",
        title: "My Resource"

      @impl true
      def read(_params, frame), do: {:reply, Response.resource(), frame}
    end

    defmodule ResourceWithoutTitle do
      @moduledoc false

      use Component,
        type: :resource,
        uri: "test://resource-without-title"

      @impl true
      def read(_params, frame), do: {:reply, Response.resource(), frame}
    end

    test "defines title/0 when the :title option is passed" do
      assert ResourceWithTitle.title() == "My Resource"
    end

    test "does not export title/0 when the :title option is omitted" do
      refute function_exported?(ResourceWithoutTitle, :title, 0)
    end
  end

  describe "Prompt component title option" do
    defmodule PromptWithTitle do
      @moduledoc false

      use Component, type: :prompt, title: "My Prompt"

      schema do
        field :input, :string
      end

      @impl true
      def get_messages(_params, frame) do
        response = Response.user_message(Response.prompt(), "test")
        {:reply, response, frame}
      end
    end

    defmodule PromptWithoutTitle do
      @moduledoc false

      use Component, type: :prompt

      schema do
        field :input, :string
      end

      @impl true
      def get_messages(_params, frame) do
        response = Response.user_message(Response.prompt(), "test")
        {:reply, response, frame}
      end
    end

    test "defines title/0 when the :title option is passed" do
      assert PromptWithTitle.title() == "My Prompt"
    end

    test "does not export title/0 when the :title option is omitted" do
      refute function_exported?(PromptWithoutTitle, :title, 0)
    end
  end
end
