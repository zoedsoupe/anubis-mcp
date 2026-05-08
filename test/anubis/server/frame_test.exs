defmodule Anubis.Server.FrameTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Component.Resource
  alias Anubis.Server.Context
  alias Anubis.Server.Frame

  describe "assign/2 preserves context" do
    test "assigning values does not modify context" do
      original_context = %Context{
        session_id: "session-123",
        client_info: %{"name" => "test"},
        headers: %{"authorization" => "Bearer token"},
        remote_ip: {127, 0, 0, 1}
      }

      frame = %Frame{context: original_context, assigns: %{existing: true}}
      updated_frame = Frame.assign(frame, %{new_key: "value", another: 42})

      assert updated_frame.context == original_context
      assert updated_frame.assigns[:new_key] == "value"
      assert updated_frame.assigns[:another] == 42
      assert updated_frame.assigns[:existing] == true
    end

    test "assigning does not allow overwriting context struct fields" do
      context = %Context{session_id: "original"}
      frame = %Frame{context: context}

      updated_frame = Frame.assign(frame, %{context: "malicious"})

      assert updated_frame.context == context
      assert updated_frame.assigns[:context] == "malicious"
    end
  end

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

  describe "subscribe_resource/2" do
    test "records a subscription for the given URI" do
      frame = Frame.subscribe_resource(Frame.new(), "file:///foo")

      assert Frame.resource_subscribed?(frame, "file:///foo")
    end

    test "is idempotent — subscribing twice keeps a single entry" do
      frame =
        Frame.new()
        |> Frame.subscribe_resource("file:///foo")
        |> Frame.subscribe_resource("file:///foo")

      assert MapSet.size(frame.resource_subscriptions) == 1
    end

    test "URIs do not need to refer to a registered resource" do
      frame = Frame.subscribe_resource(Frame.new(), "does-not-exist:///x")

      assert Frame.resource_subscribed?(frame, "does-not-exist:///x")
    end
  end

  describe "unsubscribe_resource/2" do
    test "removes an existing subscription" do
      frame =
        Frame.new()
        |> Frame.subscribe_resource("file:///foo")
        |> Frame.unsubscribe_resource("file:///foo")

      refute Frame.resource_subscribed?(frame, "file:///foo")
    end

    test "is a no-op for a URI that was not subscribed" do
      frame = Frame.unsubscribe_resource(Frame.new(), "file:///never-subscribed")

      assert MapSet.size(frame.resource_subscriptions) == 0
    end

    test "leaves other subscriptions intact" do
      frame =
        Frame.new()
        |> Frame.subscribe_resource("file:///a")
        |> Frame.subscribe_resource("file:///b")
        |> Frame.unsubscribe_resource("file:///a")

      refute Frame.resource_subscribed?(frame, "file:///a")
      assert Frame.resource_subscribed?(frame, "file:///b")
    end
  end

  describe "resource_subscribed?/2" do
    test "returns false for an empty frame" do
      refute Frame.resource_subscribed?(Frame.new(), "file:///foo")
    end

    test "returns true for a subscribed URI" do
      frame = Frame.subscribe_resource(Frame.new(), "file:///foo")

      assert Frame.resource_subscribed?(frame, "file:///foo")
    end
  end

  describe "to_saved/1 and from_saved/1 round-trip" do
    test "preserves subscriptions across persistence" do
      frame =
        Frame.new()
        |> Frame.subscribe_resource("file:///a")
        |> Frame.subscribe_resource("file:///b")

      restored = frame |> Frame.to_saved() |> Frame.from_saved()

      assert Frame.resource_subscribed?(restored, "file:///a")
      assert Frame.resource_subscribed?(restored, "file:///b")
    end

    test "serializes subscriptions as a list (JSON-friendly)" do
      frame = Frame.subscribe_resource(Frame.new(), "file:///x")

      saved = Frame.to_saved(frame)

      assert is_list(saved["resource_subscriptions"])
      assert "file:///x" in saved["resource_subscriptions"]
    end

    test "from_saved/1 restores an empty MapSet when key is missing" do
      restored = Frame.from_saved(%{"assigns" => %{}})

      assert restored.resource_subscriptions == MapSet.new()
    end
  end
end
