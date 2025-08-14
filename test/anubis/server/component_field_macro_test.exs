defmodule Anubis.Server.ComponentFieldMacroTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Component
  alias TestTools.DeeplyNestedTool
  alias TestTools.LegacyTool
  alias TestTools.NestedFieldTool
  alias TestTools.SingleNestedFieldTool

  describe "field macro with nested do blocks" do
    test "generates correct JSON Schema with nested fields" do
      json_schema = NestedFieldTool.input_schema()

      assert json_schema == %{
               "type" => "object",
               "properties" => %{
                 "name" => %{
                   "type" => "string",
                   "description" => "Full name"
                 },
                 "address" => %{
                   "type" => "object",
                   "description" => "Mailing address",
                   "properties" => %{
                     "street" => %{"type" => "string"},
                     "city" => %{"type" => "string"},
                     "state" => %{"type" => "string"},
                     "zip" => %{
                       "type" => "string",
                       "format" => "postal-code"
                     }
                   },
                   "required" => ["street", "city"]
                 },
                 "contact" => %{
                   "type" => "object",
                   "properties" => %{
                     "email" => %{
                       "type" => "string",
                       "format" => "email",
                       "description" => "Contact email"
                     },
                     "phone" => %{
                       "type" => "string",
                       "format" => "phone"
                     }
                   }
                 }
               },
               "required" => ["name"]
             }

      assert {:ok, _} =
               NestedFieldTool.mcp_schema(%{
                 name: "John Doe",
                 address: %{
                   street: "123 Main St",
                   city: "New York",
                   state: "NY",
                   zip: "10001"
                 },
                 contact: %{
                   email: "john@example.com",
                   phone: "+1-555-0123"
                 }
               })

      assert {:error, _} =
               NestedFieldTool.mcp_schema(%{
                 name: "John Doe",
                 address: %{
                   city: "New York"
                 }
               })
    end

    test "supports single field in nested block" do
      json_schema = SingleNestedFieldTool.input_schema()

      assert json_schema == %{
               "type" => "object",
               "properties" => %{
                 "user" => %{
                   "type" => "object",
                   "description" => "User information",
                   "properties" => %{
                     "id" => %{
                       "type" => "string",
                       "format" => "uuid"
                     }
                   },
                   "required" => ["id"]
                 }
               }
             }
    end

    test "supports enum fields with type specification" do
      alias TestTools.EnumWithTypeTool

      json_schema = EnumWithTypeTool.input_schema()

      assert json_schema == %{
               "type" => "object",
               "properties" => %{
                 "weight" => %{"type" => "integer"},
                 "unit" => %{
                   "type" => "string",
                   "enum" => ["kg", "lb"]
                 },
                 "status" => %{
                   "type" => "string",
                   "enum" => ["active", "inactive", "pending"]
                 }
               },
               "required" => ["unit", "weight"]
             }

      assert {:ok, _} =
               EnumWithTypeTool.mcp_schema(%{
                 weight: 70,
                 unit: "kg",
                 status: "active"
               })

      assert {:error, _} =
               EnumWithTypeTool.mcp_schema(%{
                 weight: 70
               })
    end

    test "supports deeply nested fields" do
      json_schema = DeeplyNestedTool.input_schema()

      assert json_schema["properties"]["organization"]["properties"]["admin"][
               "properties"
             ]["permissions"] == %{
               "type" => "object",
               "properties" => %{
                 "read" => %{"type" => "boolean"},
                 "write" => %{"type" => "boolean"},
                 "delete" => %{"type" => "boolean"}
               },
               "required" => ["read", "write"]
             }
    end
  end

  describe "cleaner schema syntax without braces" do
    test "allows defining schemas without explicit map braces" do
      defmodule CleanSyntaxTool do
        @moduledoc "Tool demonstrating clean syntax"

        use Component, type: :tool

        schema do
          field(:title, {:required, :string}, description: "Title of the item")

          field(:priority, {:enum, ["low", "medium", "high"]}, description: "Priority level")

          embeds_one :metadata do
            field(:created_at, :string, format: "date-time")
            field(:tags, {:list, :string})
          end
        end

        @impl true
        def execute(params, frame) do
          {:reply, %{processed: params}, frame}
        end
      end

      json_schema = CleanSyntaxTool.input_schema()

      assert json_schema["properties"]["title"]["description"] == "Title of the item"

      assert json_schema["properties"]["priority"]["enum"] == [
               "low",
               "medium",
               "high"
             ]

      assert json_schema["properties"]["metadata"]["properties"]["created_at"][
               "format"
             ] == "date-time"

      assert json_schema["required"] == ["title"]
    end
  end

  describe "GitHub issues integration tests with field macro" do
    test "field constraints work end-to-end in actual tools" do
      defmodule ConstraintTestTool do
        @moduledoc "Tool for testing field constraints end-to-end"
        use Component, type: :tool

        alias Anubis.Server.Response

        schema do
          field :username, :string, required: true, min_length: 3, max_length: 20, description: "Username"

          field :email, :string,
            required: true,
            regex: ~r/^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/,
            description: "Email"

          field :age, :integer, min: 18, max: 120, description: "Age"
          field :role, {:enum, ["admin", "user", "guest"]}, required: true, description: "User role"
          field :priority, :integer, min: 1, max: 10, description: "Priority level"
        end

        @impl true
        def execute(params, frame) do
          {:reply, Response.text(Response.tool(), "User: #{params.username}"), frame}
        end
      end

      # Test JSON schema generation works correctly
      json_schema = ConstraintTestTool.input_schema()

      # Test string constraints
      assert json_schema["properties"]["username"]["minLength"] == 3
      assert json_schema["properties"]["username"]["maxLength"] == 20
      assert json_schema["properties"]["email"]["pattern"] == "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$"

      # Test numeric constraints
      assert json_schema["properties"]["age"]["minimum"] == 18
      assert json_schema["properties"]["age"]["maximum"] == 120
      assert json_schema["properties"]["priority"]["minimum"] == 1
      assert json_schema["properties"]["priority"]["maximum"] == 10

      # Test enum constraints
      assert json_schema["properties"]["role"]["enum"] == ["admin", "user", "guest"]

      # Test required fields
      required_fields = json_schema["required"]
      assert "username" in required_fields
      assert "email" in required_fields
      assert "role" in required_fields
      refute "age" in required_fields
      refute "priority" in required_fields

      # Test validation works
      valid_params = %{
        username: "alice",
        email: "alice@example.com",
        age: 25,
        role: "admin",
        priority: 5
      }

      assert {:ok, _} = ConstraintTestTool.mcp_schema(valid_params)

      # Test constraint violations
      invalid_params = %{
        # too short
        username: "ab",
        email: "invalid-email",
        # too young
        age: 17,
        role: "invalid_role",
        # too high
        priority: 15
      }

      assert {:error, _} = ConstraintTestTool.mcp_schema(invalid_params)
    end

    test "enum fields generate correct schema structure matching johns10 issue" do
      defmodule ComponentTypeTool do
        @moduledoc "Tool matching the johns10 issue example"
        use Component, type: :tool

        alias Anubis.Server.Response

        schema do
          field :name, :string, required: true

          field :type, :atom,
            required: true,
            enum: [:genserver, :context, :coordination_context, :schema, :repository, :task, :registry, :other]

          field :module_name, :string, required: true
          field :description, :string, required: false
        end

        @impl true
        def execute(params, frame) do
          {:reply, Response.text(Response.tool(), "Component: #{params.name}"), frame}
        end
      end

      json_schema = ComponentTypeTool.input_schema()

      # This was the exact issue: type field was empty object instead of having enum
      refute json_schema["properties"]["type"] == %{}

      assert json_schema["properties"]["type"]["enum"] == [
               :genserver,
               :context,
               :coordination_context,
               :schema,
               :repository,
               :task,
               :registry,
               :other
             ]

      # Required should be array format, not numbered object keys
      assert is_list(json_schema["required"])
      assert "name" in json_schema["required"]
      assert "type" in json_schema["required"]
      assert "module_name" in json_schema["required"]
      refute "description" in json_schema["required"]

      # Verify the structure matches expected MCP format
      assert json_schema["type"] == "object"
      assert Map.has_key?(json_schema, "properties")
      assert Map.has_key?(json_schema, "required")
    end

    test "complex nested structures with constraints work correctly" do
      defmodule ComplexConstraintTool do
        @moduledoc "Tool with nested constraints"
        use Component, type: :tool

        alias Anubis.Server.Response

        schema do
          field :title, :string, required: true, min_length: 1, max_length: 100

          embeds_one :settings, required: true do
            field :environment, :string, required: true, enum: ["dev", "staging", "prod"]
            field :timeout, :integer, min: 1000, max: 60_000
            field :debug, :boolean
          end

          embeds_many :features do
            field :name, :string, required: true, regex: ~r/^[a-z_]+$/
            field :enabled, :boolean, required: true
            field :config, :string, max_length: 200
          end
        end

        @impl true
        def execute(params, frame) do
          {:reply, Response.text(Response.tool(), "Config: #{params.title}"), frame}
        end
      end

      json_schema = ComplexConstraintTool.input_schema()

      # Test root level constraints
      assert json_schema["properties"]["title"]["minLength"] == 1
      assert json_schema["properties"]["title"]["maxLength"] == 100

      # Test nested object constraints
      settings_props = json_schema["properties"]["settings"]["properties"]
      assert settings_props["environment"]["enum"] == ["dev", "staging", "prod"]
      assert settings_props["timeout"]["minimum"] == 1000
      assert settings_props["timeout"]["maximum"] == 60_000

      # Test array item constraints
      features_props = json_schema["properties"]["features"]["items"]["properties"]
      assert features_props["name"]["pattern"] == "^[a-z_]+$"
      assert features_props["config"]["maxLength"] == 200

      # Test nested required fields
      assert json_schema["required"] == ["title", "settings"]
      assert json_schema["properties"]["settings"]["required"] == ["environment"]
      # Required fields order doesn't matter, just check both are present
      required_fields = json_schema["properties"]["features"]["items"]["required"]
      assert "name" in required_fields
      assert "enabled" in required_fields
      assert length(required_fields) == 2
    end

    test "natural enum syntax works with field macro" do
      defmodule NaturalEnumTool do
        @moduledoc "Tool demonstrating natural enum syntax"
        use Component, type: :tool

        alias Anubis.Server.Response

        schema do
          field :status, :enum,
            type: :string,
            values: ["draft", "published", "archived"],
            required: true,
            description: "Post status"

          field :priority, :enum, type: :integer, values: [1, 2, 3, 4, 5], description: "Priority level"
          field :category, :enum, values: ["tech", "business", "personal"], description: "Category (defaults to string)"
        end

        @impl true
        def execute(params, frame) do
          {:reply, Response.text(Response.tool(), "Status: #{params.status}"), frame}
        end
      end

      json_schema = NaturalEnumTool.input_schema()

      # Test string enum with explicit type
      assert json_schema["properties"]["status"]["enum"] == ["draft", "published", "archived"]
      assert json_schema["properties"]["status"]["type"] == "string"
      assert json_schema["properties"]["status"]["description"] == "Post status"

      # Test integer enum
      assert json_schema["properties"]["priority"]["enum"] == [1, 2, 3, 4, 5]
      assert json_schema["properties"]["priority"]["type"] == "integer"

      # Test enum with default string type
      assert json_schema["properties"]["category"]["enum"] == ["tech", "business", "personal"]
      assert json_schema["properties"]["category"]["type"] == "string"

      # Test required
      assert json_schema["required"] == ["status"]

      # Test validation works
      assert {:ok, _} = NaturalEnumTool.mcp_schema(%{status: "draft", priority: 3, category: "tech"})
      assert {:error, _} = NaturalEnumTool.mcp_schema(%{status: "invalid"})
    end
  end

  describe "backward compatibility with legacy schemas" do
    test "legacy Peri schema without field macros still works" do
      json_schema = LegacyTool.input_schema()

      assert json_schema == %{
               "type" => "object",
               "properties" => %{
                 "name" => %{"type" => "string"},
                 "age" => %{"type" => "integer"},
                 "email" => %{"type" => "string"},
                 "tags" => %{
                   "type" => "array",
                   "items" => %{"type" => "string"}
                 },
                 "metadata" => %{
                   "type" => "object",
                   "properties" => %{
                     "created_at" => %{"type" => "string"},
                     "updated_at" => %{"type" => "string"}
                   }
                 }
               },
               "required" => ["name"]
             }
    end

    test "legacy schema Peri validation works correctly" do
      assert {:ok, _} =
               LegacyTool.mcp_schema(%{
                 name: "John Doe",
                 age: 30,
                 email: "john@example.com",
                 tags: ["developer", "elixir"],
                 metadata: %{
                   created_at: "2024-01-01",
                   updated_at: "2024-01-02"
                 }
               })

      assert {:ok, validated} =
               LegacyTool.mcp_schema(%{
                 name: "Jane Doe"
               })

      assert validated.age == 25

      assert {:error, _} =
               LegacyTool.mcp_schema(%{
                 age: 30,
                 email: "test@example.com"
               })
    end

    test "mixing field macros and legacy schemas in different tools" do
      nested_schema = NestedFieldTool.input_schema()
      legacy_schema = LegacyTool.input_schema()

      refute nested_schema == legacy_schema

      assert nested_schema["type"] == "object"
      assert legacy_schema["type"] == "object"
      assert is_map(nested_schema["properties"])
      assert is_map(legacy_schema["properties"])
    end
  end
end
