defmodule Anubis.Server.Component.ResourceTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Component

  describe "Component macro with uri_template option" do
    defmodule TestResourceTemplate do
      @moduledoc "Test resource template component"

      use Component,
        type: :resource,
        uri_template: "test:///{category}/{id}",
        name: "test_template",
        description: "Test resource template",
        mime_type: "application/json"

      alias Anubis.MCP.Error
      alias Anubis.Server.Response

      @impl true
      def read(%{"uri" => "test:///" <> _rest}, frame) do
        {:reply, Response.json(Response.resource(), %{}), frame}
      end

      def read(_params, frame) do
        {:error, Error.resource(:not_found, %{}), frame}
      end
    end

    test "generates uri_template/0 callback" do
      assert TestResourceTemplate.uri_template() == "test:///{category}/{id}"
    end

    test "generates name/0 callback" do
      assert TestResourceTemplate.name() == "test_template"
    end

    test "generates mime_type/0 callback" do
      assert TestResourceTemplate.mime_type() == "application/json"
    end

    test "does not generate uri/0 callback" do
      refute function_exported?(TestResourceTemplate, :uri, 0)
    end
  end

  describe "Component macro with uri option" do
    defmodule TestStaticResource do
      @moduledoc "Test static resource component"

      use Component,
        type: :resource,
        uri: "test:///static",
        name: "test_static",
        mime_type: "text/plain"

      alias Anubis.Server.Response

      @impl true
      def read(_params, frame) do
        {:reply, Response.text(Response.resource(), "static content"), frame}
      end
    end

    test "generates uri/0 callback" do
      assert TestStaticResource.uri() == "test:///static"
    end

    test "does not generate uri_template/0 callback" do
      refute function_exported?(TestStaticResource, :uri_template, 0)
    end
  end
end
