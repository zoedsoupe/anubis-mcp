defmodule Anubis.ServerTest do
  use ExUnit.Case, async: true

  alias Anubis.Server
  alias Anubis.Server.Component
  alias Anubis.Server.Component.Resource

  describe "parse_components/1 with resource templates" do
    defmodule TestResourceTemplate do
      @moduledoc "Test resource template for parsing"

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

    test "parses resource template component correctly" do
      [resource] = Server.parse_components({:resource, "test_template", TestResourceTemplate})

      assert %Resource{} = resource
      assert resource.uri_template == "test:///{category}/{id}"
      assert resource.name == "test_template"
      assert resource.description == "Test resource template for parsing"
      assert resource.mime_type == "application/json"
      assert resource.handler == TestResourceTemplate
      assert is_nil(resource.uri)
    end
  end

  describe "parse_components/1 with static resources" do
    defmodule TestStaticResource do
      @moduledoc "Test static resource for parsing"

      use Component,
        type: :resource,
        uri: "test:///static",
        name: "test_static",
        mime_type: "text/plain"

      alias Anubis.Server.Response

      @impl true
      def read(_params, frame) do
        {:reply, Response.text(Response.resource(), "content"), frame}
      end
    end

    test "parses static resource component correctly" do
      [resource] = Server.parse_components({:resource, "test_static", TestStaticResource})

      assert %Resource{} = resource
      assert resource.uri == "test:///static"
      assert resource.name == "test_static"
      assert resource.mime_type == "text/plain"
      assert resource.handler == TestStaticResource
      assert is_nil(resource.uri_template)
    end
  end
end
