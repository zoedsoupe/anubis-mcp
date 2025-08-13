defmodule Anubis.Server.Component.Schema do
  @moduledoc false

  alias Anubis.Server.Component

  @type schema :: map() | list()
  @type field_type :: atom() | tuple()
  @type json_schema :: map()
  @type prompt_argument :: map()

  @spec normalize(schema()) :: map()
  def normalize(schema) when is_map(schema) do
    Map.new(schema, fn {key, value} -> {key, normalize_field(value)} end)
  end

  def normalize(schema) when is_list(schema), do: Map.new(schema)

  def normalize(schema), do: schema

  @spec to_json_schema(schema() | nil) :: json_schema()
  def to_json_schema(nil), do: %{"type" => "object"}

  def to_json_schema(schema) when is_map(schema) do
    schema = normalize(schema)

    properties =
      Map.new(schema, fn {key, type} -> {to_string(key), convert_type(type)} end)

    required =
      schema
      |> Enum.filter(fn {_key, type} -> required?(type) end)
      |> Enum.map(fn {key, _type} -> to_string(key) end)

    base = %{"type" => "object", "properties" => properties}

    if Enum.empty?(required), do: base, else: Map.put(base, "required", required)
  end

  @spec to_prompt_arguments(schema() | nil) :: [prompt_argument()]
  def to_prompt_arguments(nil), do: []

  def to_prompt_arguments(schema) when is_map(schema) do
    Enum.map(schema, fn {key, type} ->
      %{
        "name" => to_string(key),
        "description" => describe_type(type),
        "required" => required?(type)
      }
    end)
  end

  @spec format_errors([map()] | [binary()]) :: binary()
  def format_errors(errors) when is_list(errors) do
    Enum.map_join(errors, "; ", &format_error/1)
  end

  defp format_error(%{path: path, message: message}) do
    path_str = Enum.join(path, ".")
    if path_str == "", do: message, else: "#{path_str}: #{message}"
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error, pretty: true)

  defp convert_type({:required, {:mcp_field, type, opts}}) do
    convert_type({:mcp_field, {:required, type}, opts})
  end

  defp convert_type({:required, type}), do: convert_type(type)

  defp convert_type({:mcp_field, type, opts}) when is_list(opts) do
    type
    |> convert_type()
    |> then(fn s -> Enum.reduce(opts, s, &parse_type_opt(type, &1, &2)) end)
  end

  defp convert_type(:string), do: %{"type" => "string"}
  defp convert_type(:integer), do: %{"type" => "integer"}
  defp convert_type(:float), do: %{"type" => "number"}
  defp convert_type(:boolean), do: %{"type" => "boolean"}
  defp convert_type(:any), do: %{}

  # Handle bare :enum type (will get values and type from opts via parse_type_opt)
  defp convert_type(:enum), do: %{}

  defp convert_type(:date), do: %{"type" => "string", "format" => "date"}
  defp convert_type(:time), do: %{"type" => "string", "format" => "time"}
  defp convert_type(:datetime), do: %{"type" => "string", "format" => "date-time"}

  defp convert_type(:naive_datetime), do: %{"type" => "string", "format" => "date-time"}

  defp convert_type({:string, {:regex, %Regex{source: pattern}}}) do
    %{"type" => "string", "pattern" => pattern}
  end

  defp convert_type({:string, {:min, min}}) do
    %{"type" => "string", "minLength" => min}
  end

  defp convert_type({:string, {:max, max}}) do
    %{"type" => "string", "maxLength" => max}
  end

  defp convert_type({:integer, {:eq, value}}) do
    %{"type" => "integer", "const" => value}
  end

  defp convert_type({:integer, {:neq, value}}) do
    %{"type" => "integer", "not" => %{"const" => value}}
  end

  defp convert_type({:integer, {:gt, value}}) do
    %{"type" => "integer", "exclusiveMinimum" => value}
  end

  defp convert_type({:integer, {:gte, value}}) do
    %{"type" => "integer", "minimum" => value}
  end

  defp convert_type({:integer, {:lt, value}}) do
    %{"type" => "integer", "exclusiveMaximum" => value}
  end

  defp convert_type({:integer, {:lte, value}}) do
    %{"type" => "integer", "maximum" => value}
  end

  defp convert_type({:integer, {:range, {min, max}}}) do
    %{"type" => "integer", "minimum" => min, "maximum" => max}
  end

  defp convert_type({:float, {:eq, value}}) do
    %{"type" => "number", "const" => value}
  end

  defp convert_type({:float, {:neq, value}}) do
    %{"type" => "number", "not" => %{"const" => value}}
  end

  defp convert_type({:float, {:gt, value}}) do
    %{"type" => "number", "exclusiveMinimum" => value}
  end

  defp convert_type({:float, {:gte, value}}) do
    %{"type" => "number", "minimum" => value}
  end

  defp convert_type({:float, {:lt, value}}) do
    %{"type" => "number", "exclusiveMaximum" => value}
  end

  defp convert_type({:float, {:lte, value}}) do
    %{"type" => "number", "maximum" => value}
  end

  defp convert_type({:float, {:range, {min, max}}}) do
    %{"type" => "number", "minimum" => min, "maximum" => max}
  end

  defp convert_type({:enum, values}) when is_list(values) do
    %{"enum" => values}
  end

  defp convert_type({:enum, values, type}) when is_list(values) do
    base = convert_type(type)
    Map.put(base, "enum", values)
  end

  defp convert_type({:list, item_type}) do
    %{
      "type" => "array",
      "items" => convert_type(item_type)
    }
  end

  defp convert_type({:map, value_type}) do
    %{
      "type" => "object",
      "additionalProperties" => convert_type(value_type)
    }
  end

  defp convert_type({:literal, value}), do: %{"const" => value}

  defp convert_type({:either, {type1, type2}}) do
    %{"oneOf" => [convert_type(type1), convert_type(type2)]}
  end

  defp convert_type({:oneof, types}) when is_list(types) do
    %{"oneOf" => Enum.map(types, &convert_type/1)}
  end

  defp convert_type({type, {:default, _default}}), do: convert_type(type)

  defp convert_type(nested_schema) when is_map(nested_schema) do
    to_json_schema(nested_schema)
  end

  defp convert_type(_unknown), do: %{}

  defp parse_type_opt(_type, {:format, format}, schema) do
    Map.put(schema, "format", format)
  end

  defp parse_type_opt(_type, {:description, desc}, schema) do
    Map.put(schema, "description", desc)
  end

  defp parse_type_opt(_type, {:type, json_type}, schema) do
    Map.put(schema, "type", to_string(json_type))
  end

  defp parse_type_opt(_type, {:min_length, min}, schema) do
    Map.put(schema, "minLength", min)
  end

  defp parse_type_opt(_type, {:max_length, max}, schema) do
    Map.put(schema, "maxLength", max)
  end

  defp parse_type_opt(_type, {:regex, %Regex{source: pattern}}, schema) do
    Map.put(schema, "pattern", pattern)
  end

  defp parse_type_opt(_type, {:min, min}, schema) do
    Map.put(schema, "minimum", min)
  end

  defp parse_type_opt(_type, {:max, max}, schema) do
    Map.put(schema, "maximum", max)
  end

  defp parse_type_opt(_type, {:enum, values}, schema) do
    Map.put(schema, "enum", values)
  end

  defp parse_type_opt(:enum, {:values, values}, schema) do
    schema
    |> Map.put("enum", values)
    # Default to string if type not specified
    |> Map.put_new("type", "string")
  end

  defp parse_type_opt({:required, :enum}, {:values, values}, schema) do
    schema
    |> Map.put("enum", values)
    # Default to string if type not specified
    |> Map.put_new("type", "string")
  end

  defp parse_type_opt(:enum, {:type, type}, schema) do
    Map.put(schema, "type", to_string(type))
  end

  defp parse_type_opt({:required, :enum}, {:type, type}, schema) do
    Map.put(schema, "type", to_string(type))
  end

  defp parse_type_opt(_type, _opt, schema), do: schema

  defp required?({:required, _}), do: true
  defp required?({:mcp_field, type, _opts}), do: required?(type)
  defp required?(_), do: false

  defp describe_type({:required, type}), do: "Required " <> describe_base_type(type)

  defp describe_type({:mcp_field, type, opts}) do
    Keyword.get(opts, :description) || describe_type(type)
  end

  defp describe_type({type, {:default, default}}) do
    "Optional " <> describe_base_type(type) <> " (default: #{to_string(default)})"
  end

  defp describe_type(type), do: "Optional " <> describe_base_type(type)

  defp describe_base_type(:string), do: "string parameter"
  defp describe_base_type(:integer), do: "integer parameter"
  defp describe_base_type(:float), do: "number parameter"
  defp describe_base_type(:boolean), do: "boolean parameter"

  defp describe_base_type({:enum, values}), do: "one of: #{inspect(values, pretty: true)}"

  defp describe_base_type({:list, {type, _}}), do: "array of #{describe_base_type(type)} elements parameter"

  defp describe_base_type({:list, type}), do: "array of #{describe_base_type(type)} elements parameter"

  defp describe_base_type({:map, _}), do: "object parameter"
  defp describe_base_type({type, _}), do: "#{to_string(type)} parameter"
  defp describe_base_type(schema) when is_map(schema), do: "nested object"
  defp describe_base_type(_), do: "parameter"

  @spec validator(schema()) :: (map() ->
                                  {:ok, map()} | {:error, list(Peri.Error.t())})
  def validator(schema) do
    normalized = normalize(schema)
    peri_schema = Component.__clean_schema_for_peri__(normalized)

    fn params -> Peri.validate(peri_schema, params) end
  end

  defp normalize_field({:required, type, opts}) when is_list(opts) do
    {:mcp_field, {:required, type}, opts}
  end

  defp normalize_field({:enum, values}) when is_list(values) do
    {:enum, values}
  end

  defp normalize_field({:either, {type1, type2}}) do
    {:either, {type1, type2}}
  end

  defp normalize_field({:oneof, types}) when is_list(types) do
    {:oneof, types}
  end

  defp normalize_field({type, opts}) when is_list(opts) do
    {:mcp_field, type, opts}
  end

  defp normalize_field({:object, fields}) when is_map(fields) do
    normalize(fields)
  end

  defp normalize_field({:object, fields, opts}) when is_map(fields) and is_list(opts) do
    {:mcp_field, normalize(fields), opts}
  end

  defp normalize_field({:list, item_type}) do
    {:list, normalize_field(item_type)}
  end

  defp normalize_field({:list, item_type, opts}) when is_list(opts) do
    {:mcp_field, {:list, normalize_field(item_type)}, opts}
  end

  defp normalize_field({:mcp_field, _, _} = field), do: field
  defp normalize_field(nested) when is_map(nested), do: normalize(nested)
  defp normalize_field({_type, _spec} = tuple), do: tuple
  defp normalize_field(other), do: other
end
