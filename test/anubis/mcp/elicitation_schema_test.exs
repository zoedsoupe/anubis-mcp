defmodule Anubis.MCP.ElicitationSchemaTest do
  use ExUnit.Case, async: true

  alias Anubis.MCP.ElicitationSchema

  describe "validate/1" do
    test "accepts a flat object with primitive properties" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["name"]
      }

      assert :ok = ElicitationSchema.validate(schema)
    end

    test "accepts string with format and length bounds" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "email" => %{
            "type" => "string",
            "format" => "email",
            "minLength" => 3,
            "maxLength" => 100
          }
        }
      }

      assert :ok = ElicitationSchema.validate(schema)
    end

    test "accepts each permitted format" do
      for format <- ~w(email uri date date-time) do
        schema = %{
          "type" => "object",
          "properties" => %{"v" => %{"type" => "string", "format" => format}}
        }

        assert :ok = ElicitationSchema.validate(schema), "format #{format} should be permitted"
      end
    end

    test "accepts enum strings with matching enumNames" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "color" => %{
            "type" => "string",
            "enum" => ["r", "g", "b"],
            "enumNames" => ["Red", "Green", "Blue"]
          }
        }
      }

      assert :ok = ElicitationSchema.validate(schema)
    end

    test "accepts boolean with default" do
      schema = %{
        "type" => "object",
        "properties" => %{"agreed" => %{"type" => "boolean", "default" => false}}
      }

      assert :ok = ElicitationSchema.validate(schema)
    end

    test "accepts number with min/max" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "score" => %{"type" => "number", "minimum" => 0, "maximum" => 100}
        }
      }

      assert :ok = ElicitationSchema.validate(schema)
    end

    test "rejects non-object top level" do
      assert {:error, _} = ElicitationSchema.validate(%{"type" => "array"})
      assert {:error, _} = ElicitationSchema.validate(%{"type" => "string"})
    end

    test "rejects non-map input" do
      assert {:error, _} = ElicitationSchema.validate("not a map")
      assert {:error, _} = ElicitationSchema.validate(nil)
    end

    test "rejects nested object property" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "nested" => %{
            "type" => "object",
            "properties" => %{"x" => %{"type" => "string"}}
          }
        }
      }

      assert {:error, _} = ElicitationSchema.validate(schema)
    end

    test "rejects array property" do
      schema = %{
        "type" => "object",
        "properties" => %{"tags" => %{"type" => "array", "items" => %{"type" => "string"}}}
      }

      assert {:error, _} = ElicitationSchema.validate(schema)
    end

    test "rejects unsupported string format" do
      schema = %{
        "type" => "object",
        "properties" => %{"v" => %{"type" => "string", "format" => "ipv4"}}
      }

      assert {:error, _} = ElicitationSchema.validate(schema)
    end

    test "rejects enumNames length mismatch" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "x" => %{"type" => "string", "enum" => ["a", "b"], "enumNames" => ["A"]}
        }
      }

      assert {:error, reason} = ElicitationSchema.validate(schema)
      assert reason =~ "enumNames"
    end

    test "rejects required name not present in properties" do
      schema = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}},
        "required" => ["b"]
      }

      assert {:error, reason} = ElicitationSchema.validate(schema)
      assert reason =~ "required"
    end
  end

  describe "validate_content/2" do
    @schema %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "minLength" => 1},
        "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
        "email" => %{"type" => "string", "format" => "email"},
        "active" => %{"type" => "boolean"},
        "color" => %{"type" => "string", "enum" => ["r", "g", "b"]}
      },
      "required" => ["name"]
    }

    test "accepts a fully populated valid content" do
      content = %{
        "name" => "Octocat",
        "age" => 3,
        "email" => "cat@github.com",
        "active" => true,
        "color" => "g"
      }

      assert :ok = ElicitationSchema.validate_content(content, @schema)
    end

    test "accepts content with only required fields" do
      assert :ok = ElicitationSchema.validate_content(%{"name" => "x"}, @schema)
    end

    test "rejects missing required field" do
      assert {:error, _} = ElicitationSchema.validate_content(%{"age" => 1}, @schema)
    end

    test "rejects unknown property" do
      assert {:error, _} =
               ElicitationSchema.validate_content(%{"name" => "x", "extra" => 1}, @schema)
    end

    test "rejects wrong type" do
      assert {:error, _} = ElicitationSchema.validate_content(%{"name" => 42}, @schema)
      assert {:error, _} = ElicitationSchema.validate_content(%{"name" => "x", "age" => "no"}, @schema)
    end

    test "rejects out-of-range integer" do
      assert {:error, _} =
               ElicitationSchema.validate_content(%{"name" => "x", "age" => 200}, @schema)
    end

    test "rejects malformed email" do
      assert {:error, _} =
               ElicitationSchema.validate_content(%{"name" => "x", "email" => "no-at-sign"}, @schema)
    end

    test "rejects value not in enum" do
      assert {:error, _} =
               ElicitationSchema.validate_content(%{"name" => "x", "color" => "purple"}, @schema)
    end

    test "validates date format" do
      schema = %{
        "type" => "object",
        "properties" => %{"d" => %{"type" => "string", "format" => "date"}}
      }

      assert :ok = ElicitationSchema.validate_content(%{"d" => "2024-01-15"}, schema)
      assert {:error, _} = ElicitationSchema.validate_content(%{"d" => "not-a-date"}, schema)
    end

    test "validates date-time format" do
      schema = %{
        "type" => "object",
        "properties" => %{"d" => %{"type" => "string", "format" => "date-time"}}
      }

      assert :ok =
               ElicitationSchema.validate_content(%{"d" => "2024-01-15T10:30:00Z"}, schema)

      assert {:error, _} = ElicitationSchema.validate_content(%{"d" => "2024-01-15"}, schema)
    end

    test "validates uri format" do
      schema = %{
        "type" => "object",
        "properties" => %{"u" => %{"type" => "string", "format" => "uri"}}
      }

      assert :ok = ElicitationSchema.validate_content(%{"u" => "https://example.com"}, schema)
      assert {:error, _} = ElicitationSchema.validate_content(%{"u" => "not a url"}, schema)
    end

    test "rejects non-map content" do
      assert {:error, _} = ElicitationSchema.validate_content("string", @schema)
      assert {:error, _} = ElicitationSchema.validate_content(nil, @schema)
    end
  end
end
