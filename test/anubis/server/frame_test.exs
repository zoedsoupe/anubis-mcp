defmodule Anubis.Server.FrameTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Component.Resource
  alias Anubis.Server.Frame

  describe "register_resource_template/3" do
    test "registers a resource template at runtime" do
      frame = Frame.new()

      frame =
        Frame.register_resource_template(frame, "dynamic:///{type}/{id}",
          name: "dynamic_template",
          description: "Dynamically registered template",
          mime_type: "application/json"
        )

      resources = Frame.get_resources(frame)

      assert [%Resource{} = template] = resources
      assert template.uri_template == "dynamic:///{type}/{id}"
      assert template.name == "dynamic_template"
      assert template.title == "dynamic_template"
      assert template.description == "Dynamically registered template"
      assert template.mime_type == "application/json"
      assert is_nil(template.uri)
      assert is_nil(template.handler)
    end

    test "requires name option" do
      frame = Frame.new()

      assert_raise KeyError, fn ->
        Frame.register_resource_template(frame, "dynamic:///{id}", [])
      end
    end

    test "uses custom title when provided" do
      frame = Frame.new()

      frame =
        Frame.register_resource_template(frame, "custom:///{id}",
          name: "custom_template",
          title: "Custom Template Title"
        )

      [resource] = Frame.get_resources(frame)
      assert resource.title == "Custom Template Title"
    end

    test "defaults to text/plain mime type when not specified" do
      frame = Frame.new()

      frame =
        Frame.register_resource_template(frame, "default:///{id}", name: "default_template")

      [resource] = Frame.get_resources(frame)
      assert resource.mime_type == "text/plain"
    end

    test "allows multiple templates to be registered" do
      frame = Frame.new()

      frame =
        frame
        |> Frame.register_resource_template("first:///{id}", name: "first")
        |> Frame.register_resource_template("second:///{id}", name: "second")

      resources = Frame.get_resources(frame)
      assert length(resources) == 2
      assert Enum.any?(resources, &(&1.name == "first"))
      assert Enum.any?(resources, &(&1.name == "second"))
    end
  end
end
