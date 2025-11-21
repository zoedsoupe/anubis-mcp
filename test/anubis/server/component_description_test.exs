defmodule Anubis.Server.ComponentDescriptionTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Component
  alias Anubis.Server.Response

  describe "Tool component description/0 callback" do
    defmodule ToolWithModuledoc do
      @moduledoc "Tool description from moduledoc"

      use Component, type: :tool

      schema do
        field :input, :string
      end

      @impl true
      def execute(_params, frame), do: {:reply, Response.tool(), frame}
    end

    defmodule ToolWithDescriptionCallback do
      @moduledoc "Tool description from moduledoc"

      use Component, type: :tool

      schema do
        field :input, :string
      end

      @impl true
      def description, do: "Tool description from description/0 callback"

      @impl true
      def execute(_params, frame), do: {:reply, Response.tool(), frame}
    end

    defmodule ToolWithoutDescription do
      @moduledoc false

      use Component, type: :tool

      schema do
        field :input, :string
      end

      @impl true
      def execute(_params, frame), do: {:reply, Response.tool(), frame}
    end

    test "uses @moduledoc when description/0 is not defined" do
      assert Component.get_description(ToolWithModuledoc) == "Tool description from moduledoc"
    end

    test "uses description/0 callback when defined, overriding @moduledoc" do
      assert Component.get_description(ToolWithDescriptionCallback) ==
               "Tool description from description/0 callback"
    end

    test "returns empty string when neither @moduledoc nor description/0 is defined" do
      assert Component.get_description(ToolWithoutDescription) == ""
    end
  end

  describe "Resource component description/0 callback" do
    defmodule ResourceWithModuledoc do
      @moduledoc "Resource description from moduledoc"

      use Component,
        type: :resource,
        uri: "test://resource"

      @impl true
      def read(_params, frame), do: {:reply, Response.resource(), frame}
    end

    defmodule ResourceWithDescriptionCallback do
      @moduledoc "Resource description from moduledoc"

      use Component,
        type: :resource,
        uri: "test://resource-with-callback"

      @impl true
      def description, do: "Resource description from description/0 callback"

      @impl true
      def read(_params, frame), do: {:reply, Response.resource(), frame}
    end

    defmodule ResourceWithoutDescription do
      @moduledoc false

      use Component,
        type: :resource,
        uri: "test://resource-without-description"

      @impl true
      def read(_params, frame), do: {:reply, Response.resource(), frame}
    end

    test "uses @moduledoc when description/0 is not defined" do
      assert Component.get_description(ResourceWithModuledoc) ==
               "Resource description from moduledoc"
    end

    test "uses description/0 callback when defined, overriding @moduledoc" do
      assert Component.get_description(ResourceWithDescriptionCallback) ==
               "Resource description from description/0 callback"
    end

    test "returns empty string when neither @moduledoc nor description/0 is defined" do
      assert Component.get_description(ResourceWithoutDescription) == ""
    end
  end

  describe "Prompt component description/0 callback" do
    defmodule PromptWithModuledoc do
      @moduledoc "Prompt description from moduledoc"

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

    defmodule PromptWithDescriptionCallback do
      @moduledoc "Prompt description from moduledoc"

      use Component, type: :prompt

      schema do
        field :input, :string
      end

      @impl true
      def description, do: "Prompt description from description/0 callback"

      @impl true
      def get_messages(_params, frame) do
        response = Response.user_message(Response.prompt(), "test")
        {:reply, response, frame}
      end
    end

    defmodule PromptWithoutDescription do
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

    test "uses @moduledoc when description/0 is not defined" do
      assert Component.get_description(PromptWithModuledoc) == "Prompt description from moduledoc"
    end

    test "uses description/0 callback when defined, overriding @moduledoc" do
      assert Component.get_description(PromptWithDescriptionCallback) ==
               "Prompt description from description/0 callback"
    end

    test "returns empty string when neither @moduledoc nor description/0 is defined" do
      assert Component.get_description(PromptWithoutDescription) == ""
    end
  end
end
