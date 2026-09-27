defmodule Anubis.Server.McpParamTest do
  use ExUnit.Case, async: true

  alias Anubis.MCP.Error
  alias Anubis.Server.Component
  alias Anubis.Server.Component.Schema
  alias Anubis.Server.McpParam

  doctest McpParam

  describe "declaring a header" do
    test "puts x-mcp-header on the parameter, nested objects included" do
      json =
        Schema.to_json_schema(%{
          region: build(:string, required: true, mcp_header: "Region"),
          limit: build(:integer, mcp_header: "Limit"),
          target: build(%{zone: build(:string, mcp_header: "Zone")}, description: "Where")
        })

      assert json["properties"]["region"]["x-mcp-header"] == "Region"
      assert json["properties"]["limit"]["x-mcp-header"] == "Limit"
      assert json["properties"]["target"]["properties"]["zone"]["x-mcp-header"] == "Zone"
      refute Map.has_key?(json["properties"]["target"], "x-mcp-header")
    end

    test "refuses a name that is not an HTTP token" do
      for name <- ["", "Two Words", "Line\nBreak", "Tab\t"] do
        assert_raise ArgumentError, ~r/HTTP token/, fn ->
          Schema.to_json_schema(%{region: build(:string, mcp_header: name)})
        end
      end
    end

    test "refuses a name used twice, regardless of case" do
      assert_raise ArgumentError, ~r/more than once/, fn ->
        Schema.to_json_schema(%{a: build(:string, mcp_header: "Region"), b: build(:string, mcp_header: "region")})
      end
    end

    test "refuses a parameter that is not a string, integer or boolean" do
      assert_raise ArgumentError, ~r/string, integer or boolean/, fn ->
        Schema.to_json_schema(%{ratio: build(:float, mcp_header: "Ratio")})
      end
    end

    test "refuses a parameter inside a list" do
      assert_raise ArgumentError, ~r/inside a list/, fn ->
        Schema.to_json_schema(%{items: build({:list, %{name: build(:string, mcp_header: "Name")}}, [])})
      end
    end
  end

  describe "validating a call" do
    setup do
      schema =
        Schema.to_json_schema(%{
          region: build(:string, mcp_header: "Region"),
          count: build(:integer, mcp_header: "Count"),
          dry_run: build(:boolean, mcp_header: "Dry-Run"),
          target: build(%{zone: build(:string, mcp_header: "Zone")}, [])
        })

      %{schema: schema}
    end

    test "accepts headers that match the arguments", %{schema: schema} do
      arguments = %{"region" => "us-west1", "count" => -7, "dry_run" => false, "target" => %{"zone" => "b"}}

      headers = %{
        "mcp-param-region" => "us-west1",
        "mcp-param-count" => "-7",
        "mcp-param-dry-run" => "false",
        "mcp-param-zone" => "b"
      }

      assert :ok = McpParam.validate(schema, arguments, headers)
    end

    test "decodes Base64 and ignores surrounding whitespace", %{schema: schema} do
      encoded = "=?base64?" <> Base.encode64("Hello, 世界") <> "?="

      assert :ok = McpParam.validate(schema, %{"region" => "Hello, 世界"}, %{"mcp-param-region" => encoded})
      assert :ok = McpParam.validate(schema, %{"region" => "us"}, %{"mcp-param-region" => "  us\t"})
    end

    test "takes a value with only the sentinel's prefix literally", %{schema: schema} do
      value = "=?base64?SGVsbG8="
      assert :ok = McpParam.validate(schema, %{"region" => value}, %{"mcp-param-region" => value})
    end

    test "expects no header for an absent or null argument", %{schema: schema} do
      assert :ok = McpParam.validate(schema, %{}, %{})
      assert :ok = McpParam.validate(schema, %{"region" => nil}, %{})
    end

    test "rejects every disagreement with -32020", %{schema: schema} do
      cases = [
        {%{"region" => "us-west1"}, %{"mcp-param-region" => "eu-west1"}},
        {%{"region" => "us-west1"}, %{}},
        {%{}, %{"mcp-param-region" => "us-west1"}},
        {%{"region" => "Hello"}, %{"mcp-param-region" => "=?base64?SGVsbG8?="}},
        {%{"region" => "Hello"}, %{"mcp-param-region" => "=?base64?SGVs!!!bG8=?="}},
        {%{"region" => "a\u0001b"}, %{"mcp-param-region" => "a\u0001b"}},
        {%{"count" => 7}, %{"mcp-param-count" => "07"}},
        {%{"dry_run" => true}, %{"mcp-param-dry-run" => "True"}},
        {%{"target" => %{"zone" => "b"}}, %{"mcp-param-zone" => "c"}}
      ]

      for {arguments, headers} <- cases do
        assert {:error, %Error{code: -32_020}} = McpParam.validate(schema, arguments, headers),
               inspect({arguments, headers})
      end
    end

    test "has nothing to check without annotations" do
      assert :ok = McpParam.validate(%{"type" => "object"}, %{"a" => 1}, %{"mcp-param-a" => "2"})
      assert :ok = McpParam.validate(nil, nil, %{})
    end
  end

  defp build(type, opts), do: Component.__build_field__(type, opts)
end
