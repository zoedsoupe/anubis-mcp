defmodule Anubis.MCP.ElicitationSchema do
  @moduledoc """
  Validator for the restricted JSON Schema subset allowed in elicitation requests.

  Per the MCP 2025-06-18 specification, an `elicitation/create` `requestedSchema`
  must be a flat object whose properties are all primitives. This module validates
  both the schema map itself (`validate/1`) and content payloads against a
  previously validated schema (`validate_content/2`).

  Permitted property schemas:

    * `string` with optional `minLength`, `maxLength`, `format`
      (one of `"email"`, `"uri"`, `"date"`, `"date-time"`)
    * `string` enum with `enum` and optional matching `enumNames`
    * `number` / `integer` with optional `minimum`, `maximum`
    * `boolean` with optional `default`
  """

  import Peri

  @permitted_string_formats ~w(email uri date date-time)

  @string_property_schema %{
    "type" => {:required, {:literal, "string"}},
    "title" => :string,
    "description" => :string,
    "minLength" => {:integer, {:gte, 0}},
    "maxLength" => {:integer, {:gte, 0}},
    "format" => {:enum, @permitted_string_formats}
  }

  @enum_property_schema %{
    "type" => {:required, {:literal, "string"}},
    "title" => :string,
    "description" => :string,
    "enum" => {:required, {:list, :string}},
    "enumNames" => {:list, :string}
  }

  @numeric_property_schema %{
    "type" => {:required, {:enum, ~w(number integer)}},
    "title" => :string,
    "description" => :string,
    "minimum" => {:either, {:integer, :float}},
    "maximum" => {:either, {:integer, :float}}
  }

  @boolean_property_schema %{
    "type" => {:required, {:literal, "boolean"}},
    "title" => :string,
    "description" => :string,
    "default" => :boolean
  }

  defschema(:requested_schema, %{
    "type" => {:required, {:literal, "object"}},
    "properties" => {:map, :string, {:custom, &__MODULE__.validate_property/1}},
    "required" => {:list, :string}
  })

  @doc """
  Validates a `requestedSchema` map fits the elicitation subset.

  Returns `:ok` or `{:error, reason}` where `reason` is a human-readable string.
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(schema) when is_map(schema) do
    with {:ok, validated} <- requested_schema(schema),
         :ok <- validate_required_declared(validated) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, errors} when is_list(errors) -> {:error, format_errors(errors)}
    end
  end

  def validate(_), do: {:error, "requestedSchema must be a map"}

  @doc false
  @spec validate_property(term()) :: :ok | {:error, String.t(), keyword()}
  def validate_property(prop) when is_map(prop) do
    schema = dispatch_property_schema(prop)

    with {:ok, _validated} <- Peri.validate(schema, prop),
         :ok <- validate_enum_names_match(prop) do
      :ok
    else
      {:error, errors} when is_list(errors) ->
        {:error, format_errors(errors), []}

      {:error, reason} when is_binary(reason) ->
        {:error, reason, []}
    end
  end

  def validate_property(other), do: {:error, "property must be a map, got %{actual}", actual: inspect(other)}

  defp dispatch_property_schema(%{"enum" => _}), do: @enum_property_schema
  defp dispatch_property_schema(%{"type" => "string"}), do: @string_property_schema
  defp dispatch_property_schema(%{"type" => "number"}), do: @numeric_property_schema
  defp dispatch_property_schema(%{"type" => "integer"}), do: @numeric_property_schema
  defp dispatch_property_schema(%{"type" => "boolean"}), do: @boolean_property_schema
  defp dispatch_property_schema(_), do: @string_property_schema

  defp validate_enum_names_match(%{"enum" => enum, "enumNames" => names}) do
    if length(enum) == length(names) do
      :ok
    else
      {:error, "enumNames must have the same length as enum"}
    end
  end

  defp validate_enum_names_match(_), do: :ok

  defp validate_required_declared(%{"required" => required, "properties" => properties})
       when is_list(required) and is_map(properties) do
    case Enum.find(required, fn name -> not Map.has_key?(properties, name) end) do
      nil -> :ok
      missing -> {:error, "required property #{inspect(missing)} is not declared in properties"}
    end
  end

  defp validate_required_declared(_), do: :ok

  @doc """
  Validates a content map against an already-validated elicitation schema.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_content(term(), map()) :: :ok | {:error, String.t()}
  def validate_content(content, %{"type" => "object"} = requested) when is_map(content) do
    properties = Map.get(requested, "properties", %{})
    required = Map.get(requested, "required", [])

    with :ok <- reject_unknown_keys(content, properties) do
      peri_schema = build_content_schema(properties, required)

      case Peri.validate(peri_schema, content, mode: :strict) do
        {:ok, _validated} -> :ok
        {:error, errors} when is_list(errors) -> {:error, format_errors(errors)}
      end
    end
  end

  def validate_content(content, %{"type" => "object"}) do
    {:error, "content must be a map, got #{inspect(content)}"}
  end

  def validate_content(_content, _schema) do
    {:error, "schema must be an object schema"}
  end

  defp reject_unknown_keys(content, properties) do
    case Enum.find(Map.keys(content), fn k -> not Map.has_key?(properties, k) end) do
      nil -> :ok
      key -> {:error, "unknown property #{inspect(key)}"}
    end
  end

  defp build_content_schema(properties, required) do
    required_set = MapSet.new(required)

    Map.new(properties, fn {name, prop_schema} ->
      type = property_to_peri(prop_schema)
      type = if MapSet.member?(required_set, name), do: {:required, type}, else: type
      {name, type}
    end)
  end

  defp property_to_peri(%{"enum" => values}), do: {:enum, values}

  defp property_to_peri(%{"type" => "string"} = s) do
    constraints =
      []
      |> add_constraint(s, "minLength", :min)
      |> add_constraint(s, "maxLength", :max)

    base =
      case constraints do
        [] -> :string
        [single] -> {:string, single}
        many -> {:string, many}
      end

    case Map.get(s, "format") do
      nil -> base
      format -> {:custom, {__MODULE__, :validate_string_format, [format, base]}}
    end
  end

  defp property_to_peri(%{"type" => "integer"} = s) do
    case numeric_constraints(s) do
      [] -> :integer
      [single] -> {:integer, single}
      many -> {:integer, many}
    end
  end

  defp property_to_peri(%{"type" => "number"} = s) do
    case numeric_constraints(s) do
      [] -> {:either, {:integer, :float}}
      [single] -> {:either, {{:integer, single}, {:float, single}}}
      many -> {:either, {{:integer, many}, {:float, many}}}
    end
  end

  defp property_to_peri(%{"type" => "boolean"}), do: :boolean

  defp property_to_peri(_), do: :any

  defp add_constraint(acc, schema, json_key, peri_key) do
    case Map.fetch(schema, json_key) do
      {:ok, value} -> [{peri_key, value} | acc]
      :error -> acc
    end
  end

  defp numeric_constraints(schema) do
    []
    |> add_constraint(schema, "minimum", :gte)
    |> add_constraint(schema, "maximum", :lte)
  end

  @doc false
  @spec validate_string_format(term(), String.t(), term()) ::
          :ok | {:error, String.t(), keyword()}
  def validate_string_format(value, format, base_type) do
    with :ok <- run_base_string(value, base_type),
         :ok <- check_format(value, format) do
      :ok
    else
      {:error, reason} -> {:error, reason, []}
    end
  end

  defp run_base_string(value, :string) when is_binary(value), do: :ok
  defp run_base_string(value, :string), do: {:error, "expected string, got #{inspect(value)}"}

  defp run_base_string(value, base) do
    case Peri.validate(base, value) do
      {:ok, _} -> :ok
      {:error, errors} when is_list(errors) -> {:error, format_errors(errors)}
    end
  end

  defp check_format(value, "email") when is_binary(value) do
    if String.match?(value, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) do
      :ok
    else
      {:error, "value is not a valid email"}
    end
  end

  defp check_format(value, "uri") when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" -> :ok
      _ -> {:error, "value is not a valid URI"}
    end
  end

  defp check_format(value, "date") when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _} -> :ok
      _ -> {:error, "value is not a valid ISO 8601 date"}
    end
  end

  defp check_format(value, "date-time") when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> :ok
      _ -> {:error, "value is not a valid ISO 8601 date-time"}
    end
  end

  defp check_format(value, format) do
    {:error, "value #{inspect(value)} is not a valid #{format}"}
  end

  defp format_errors(errors) do
    errors
    |> List.wrap()
    |> Enum.map_join("; ", &format_error/1)
  end

  defp format_error(%Peri.Error{message: message, path: path}) when path in [nil, []], do: message
  defp format_error(%Peri.Error{message: message, path: path}), do: "#{Enum.join(path, ".")}: #{message}"
  defp format_error(other), do: inspect(other)
end
