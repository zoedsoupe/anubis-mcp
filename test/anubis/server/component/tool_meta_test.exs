defmodule Anubis.Server.Component.ToolMetaTest do
  use Anubis.MCP.Case, async: true

  alias Anubis.Server.Component.Tool

  describe "tool _meta JSON encoding" do
    test "tool with meta includes _meta in JSON output" do
      tool = %Tool{
        name: "test_tool",
        description: "A test tool",
        input_schema: %{"type" => "object", "properties" => %{}},
        meta: %{"source" => "test", "version" => 2}
      }

      encoded = JSON.encode!(tool)
      decoded = JSON.decode!(encoded)

      assert decoded["_meta"] == %{"source" => "test", "version" => 2}
      assert decoded["name"] == "test_tool"
      assert decoded["description"] == "A test tool"
    end

    test "tool without meta does not include _meta in JSON output" do
      tool = %Tool{
        name: "test_tool",
        description: "A test tool",
        input_schema: %{"type" => "object", "properties" => %{}}
      }

      encoded = JSON.encode!(tool)
      decoded = JSON.decode!(encoded)

      refute Map.has_key?(decoded, "_meta")
      assert decoded["name"] == "test_tool"
    end
  end

  describe "meta callback" do
    test "meta callback is optional" do
      assert function_exported?(ToolWithMeta, :meta, 0)
      refute function_exported?(ToolWithoutAnnotations, :meta, 0)
    end

    test "meta returns expected value" do
      assert ToolWithMeta.meta() == %{"source" => "test", "custom_key" => 42}
    end
  end
end
