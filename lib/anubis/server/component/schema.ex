defmodule Anubis.Server.Component.Schema do
  @moduledoc false

  alias Anubis.Server.Component
  alias Anubis.Server.McpParam

  @type schema :: map() | list()
  @type field_type :: atom() | tuple()
  @type json_schema :: map()
  @type prompt_argument :: map()

  @json_schema_dialect "https://json-schema.org/draft/2020-12/schema"

  @doc """
  Builds a JSON Schema 2020-12 object from a component's fields.

  Omits server-side defaults and preserves valid `mcp_header:` annotations.
  A nil schema produces an empty object schema. Raises `ArgumentError` for
  invalid header annotations.
  """
  @spec to_json_schema(schema() | nil) :: json_schema()
  def to_json_schema(nil), do: %{"$schema" => @json_schema_dialect, "type" => "object"}

  def to_json_schema(schema) when is_list(schema) do
    schema |> Map.new() |> to_json_schema()
  end

  def to_json_schema(schema) when is_map(schema) do
    # Defaults live in `{type, {:default, v}}` after `__build_field__/2`. Strip
    # them from JSON Schema output so consumer schemas don't surface internal
    # defaults — prompt docs and validation still use them.
    expanded = Component.__expand_user_input__(schema)

    expanded
    |> Peri.to_json_schema(exclude_meta_keys: [:default])
    |> to_json_schema_2020_12()
    |> Map.put("$schema", @json_schema_dialect)
    |> McpParam.annotate(expanded)
  end

  # Peri encodes tuples as draft-07 `"items" => [schemas]`, which JSON Schema
  # 2020-12 splits into `prefixItems` (per-position schemas) plus
  # `"items" => false` to reject extra elements. Walk the whole schema so
  # nested tuples (under `properties`, `items`, `$defs`, ...) are converted.
  defp to_json_schema_2020_12(schema) when is_map(schema) do
    schema
    |> Map.new(fn {key, value} -> {key, to_json_schema_2020_12(value)} end)
    |> convert_tuple_items()
  end

  defp to_json_schema_2020_12(list) when is_list(list) do
    Enum.map(list, &to_json_schema_2020_12/1)
  end

  defp to_json_schema_2020_12(other), do: other

  defp convert_tuple_items(%{"items" => items} = schema) when is_list(items) do
    schema
    |> Map.put("prefixItems", items)
    |> Map.put("items", false)
  end

  defp convert_tuple_items(schema), do: schema

  @spec to_prompt_arguments(schema() | nil) :: [prompt_argument()]
  def to_prompt_arguments(nil), do: []

  def to_prompt_arguments(schema) when is_list(schema) do
    schema |> Map.new() |> to_prompt_arguments()
  end

  def to_prompt_arguments(schema) when is_map(schema) do
    expanded = Component.__expand_user_input__(schema)

    Enum.map(expanded, fn {key, type} ->
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

  defp required?({:required, _}), do: true
  defp required?({:meta, type, _}), do: required?(type)
  defp required?(_), do: false

  defp describe_type({:required, {:meta, type, opts}}) do
    Keyword.get(opts, :description) || "Required " <> describe_base_type(type)
  end

  defp describe_type({:required, type}), do: "Required " <> describe_base_type(type)

  defp describe_type({:meta, type, opts}) do
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
  defp describe_base_type({:enum, values, _opts}), do: "one of: #{inspect(values, pretty: true)}"

  defp describe_base_type({:list, {type, _}}), do: "array of #{describe_base_type(type)} elements parameter"
  defp describe_base_type({:list, type}), do: "array of #{describe_base_type(type)} elements parameter"
  defp describe_base_type({:list, type, _opts}), do: "array of #{describe_base_type(type)} elements parameter"

  defp describe_base_type({:map, _}), do: "object parameter"
  defp describe_base_type({:meta, type, _}), do: describe_base_type(type)
  defp describe_base_type({type, _}), do: "#{to_string(type)} parameter"
  defp describe_base_type(schema) when is_map(schema), do: "nested object"
  defp describe_base_type(_), do: "parameter"

  @spec validator(schema()) :: (map() ->
                                  {:ok, map()} | {:error, list(Peri.Error.t())})
  def validator(schema) when is_list(schema) do
    schema |> Map.new() |> validator()
  end

  def validator(schema) do
    peri_schema = Component.__clean_schema_for_peri__(schema)
    fn params -> Peri.validate(peri_schema, params) end
  end
end
