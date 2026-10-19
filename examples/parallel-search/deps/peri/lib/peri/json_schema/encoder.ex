defmodule Peri.JSONSchema.Encoder do
  @moduledoc """
  Encodes a Peri schema definition into a JSON Schema (Draft 7) map.

  Field-level metadata attached via `{:meta, type, opts}` is read during
  encoding and surfaced as JSON Schema annotation/format keywords. See
  `@meta_keys` for the recognised vocabulary; unknown keys are dropped.

  Dynamic Peri types (`:dependent`, `:cond`, `:custom`) cannot be expressed
  statically. The `:on_unsupported` option controls the fallback:

    - `:omit` (default) — emit `%{}` (true schema)
    - `:true_schema` — same as `:omit`
    - `:raise` — raise `Peri.JSONSchema.Encoder.UnsupportedTypeError`

  The `:exclude_meta_keys` option drops listed annotation keywords from the
  output. Accepts any subset of the meta vocabulary plus `:default`. Useful
  when emitting consumer-facing JSON Schema where `default` values are
  validation-only and should not be exposed.

      Peri.to_json_schema(schema, exclude_meta_keys: [:default])

  Prefer `Peri.to_json_schema/2` as the public entry point.
  """

  @type opts :: [
          on_unsupported: :omit | :true_schema | :raise,
          exclude_meta_keys: [atom]
        ]

  defmodule UnsupportedTypeError do
    @moduledoc false
    defexception [:type, :reason]

    @impl true
    def message(%{type: type, reason: reason}) do
      "cannot encode #{inspect(type)} to JSON Schema: #{reason}"
    end
  end

  @meta_keys [
    :title,
    :description,
    :example,
    :examples,
    :deprecated,
    :default,
    :format,
    :pattern,
    :read_only,
    :write_only,
    :content_encoding,
    :content_media_type
  ]

  @meta_key_renames %{
    read_only: "readOnly",
    write_only: "writeOnly",
    content_encoding: "contentEncoding",
    content_media_type: "contentMediaType"
  }

  @spec encode(Peri.schema(), opts) :: map
  def encode(schema, opts \\ []) do
    {result, defs} = encode_with_defs(schema, opts)

    if map_size(defs) == 0 do
      result
    else
      Map.put(result, "$defs", defs)
    end
  end

  defp encode_with_defs(schema, opts) do
    Process.put(:peri_json_schema_defs, %{})

    try do
      result =
        if is_map(schema), do: encode_object(schema, opts), else: convert(schema, opts)

      defs = Process.get(:peri_json_schema_defs, %{})
      {result, defs}
    after
      Process.delete(:peri_json_schema_defs)
    end
  end

  defp encode_object(schema, opts) do
    properties =
      Map.new(schema, fn {key, type} ->
        {to_string(key), convert(type, opts)}
      end)

    required =
      schema
      |> Enum.filter(fn {_k, t} -> required?(t) end)
      |> Enum.map(fn {k, _t} -> to_string(k) end)

    base = %{"type" => "object", "properties" => properties}
    if Enum.empty?(required), do: base, else: Map.put(base, "required", required)
  end

  defp convert({:meta, type, meta_opts}, opts) when is_list(meta_opts) do
    type
    |> convert(opts)
    |> apply_meta(meta_opts, opts)
  end

  defp convert({:required, type}, opts), do: convert(type, opts)

  defp convert({type, {:default, default}}, opts) do
    base = convert(type, opts)

    if :default in Keyword.get(opts, :exclude_meta_keys, []),
      do: base,
      else: Map.put(base, "default", default)
  end

  defp convert(:string, _), do: %{"type" => "string"}
  defp convert(:integer, _), do: %{"type" => "integer"}
  defp convert(:float, _), do: %{"type" => "number"}
  defp convert(:boolean, _), do: %{"type" => "boolean"}
  defp convert(:atom, _), do: %{"type" => "string"}
  defp convert(:any, _), do: %{}
  defp convert(:map, _), do: %{"type" => "object"}
  defp convert(nil, _), do: %{"type" => "null"}

  defp convert(:date, _), do: %{"type" => "string", "format" => "date"}
  defp convert(:time, _), do: %{"type" => "string", "format" => "time"}
  defp convert(:datetime, _), do: %{"type" => "string", "format" => "date-time"}
  defp convert(:naive_datetime, _), do: %{"type" => "string", "format" => "date-time"}
  defp convert(:duration, _), do: %{"type" => "string", "format" => "duration"}

  defp convert({:literal, value}, _), do: %{"const" => value}
  defp convert({:enum, values}, _) when is_list(values), do: %{"enum" => values}

  defp convert({:enum, values, enum_opts}, encoder_opts)
       when is_list(values) and is_list(enum_opts) do
    base =
      case Keyword.fetch(enum_opts, :type) do
        :error -> %{}
        {:ok, type} -> convert(type, encoder_opts)
      end

    Map.put(base, "enum", values)
  end

  defp convert({:string, {:regex, %Regex{source: pattern}}}, _),
    do: %{"type" => "string", "pattern" => pattern}

  defp convert({:string, {:eq, value}}, _), do: %{"type" => "string", "const" => value}
  defp convert({:string, {:min, min}}, _), do: %{"type" => "string", "minLength" => min}
  defp convert({:string, {:max, max}}, _), do: %{"type" => "string", "maxLength" => max}

  defp convert({:string, opts}, encoder_opts) when is_list(opts) do
    Enum.reduce(opts, %{"type" => "string"}, fn opt, acc ->
      Map.merge(acc, convert({:string, opt}, encoder_opts))
    end)
  end

  defp convert({type, {:eq, value}}, _) when type in [:integer, :float] do
    Map.put(numeric_base(type), "const", value)
  end

  defp convert({type, {:neq, value}}, _) when type in [:integer, :float] do
    Map.put(numeric_base(type), "not", %{"const" => value})
  end

  defp convert({type, {:gt, value}}, _) when type in [:integer, :float],
    do: Map.put(numeric_base(type), "exclusiveMinimum", value)

  defp convert({type, {:gte, value}}, _) when type in [:integer, :float],
    do: Map.put(numeric_base(type), "minimum", value)

  defp convert({type, {:lt, value}}, _) when type in [:integer, :float],
    do: Map.put(numeric_base(type), "exclusiveMaximum", value)

  defp convert({type, {:lte, value}}, _) when type in [:integer, :float],
    do: Map.put(numeric_base(type), "maximum", value)

  defp convert({type, {:range, {min, max}}}, _) when type in [:integer, :float] do
    numeric_base(type)
    |> Map.put("minimum", min)
    |> Map.put("maximum", max)
  end

  defp convert({type, {:multiple_of, n}}, _) when type in [:integer, :float],
    do: Map.put(numeric_base(type), "multipleOf", n)

  defp convert({type, opts}, encoder_opts) when type in [:integer, :float] and is_list(opts) do
    Enum.reduce(opts, numeric_base(type), fn opt, acc ->
      Map.merge(acc, convert({type, opt}, encoder_opts))
    end)
  end

  defp convert({:list, item_type}, opts) do
    %{"type" => "array", "items" => convert(item_type, opts)}
  end

  defp convert({:list, item_type, list_opts}, opts) when is_list(list_opts) do
    base = %{"type" => "array", "items" => convert(item_type, opts)}

    Enum.reduce(list_opts, base, fn
      {:min, n}, acc -> Map.put(acc, "minItems", n)
      {:max, n}, acc -> Map.put(acc, "maxItems", n)
      {:unique, true}, acc -> Map.put(acc, "uniqueItems", true)
      _, acc -> acc
    end)
  end

  defp convert({:map, value_type}, opts) do
    %{"type" => "object", "additionalProperties" => convert(value_type, opts)}
  end

  defp convert({:map, _key_type, value_type}, opts) do
    %{"type" => "object", "additionalProperties" => convert(value_type, opts)}
  end

  defp convert({:tuple, types}, opts) do
    %{
      "type" => "array",
      "items" => Enum.map(types, &convert(&1, opts)),
      "minItems" => length(types),
      "maxItems" => length(types)
    }
  end

  defp convert({:either, {a, b}}, opts) do
    %{"oneOf" => [convert(a, opts), convert(b, opts)]}
  end

  defp convert({:oneof, types}, opts) when is_list(types) do
    %{"oneOf" => Enum.map(types, &convert(&1, opts))}
  end

  defp convert({:schema, type}, opts), do: convert(type, opts)

  defp convert({:schema, type, {:additional_keys, value_type}}, opts) when is_map(type) do
    type
    |> encode_object(opts)
    |> Map.put("additionalProperties", convert(value_type, opts))
  end

  defp convert({type, {:transform, _}}, opts), do: convert(type, opts)

  defp convert({type, {:encode, _}}, opts), do: convert(type, opts)

  defp convert({:coerce, _source, target}, opts), do: convert(target, opts)

  defp convert({:coerce, _source, target, _coerce_opts}, opts), do: convert(target, opts)

  defp convert({:multi, field, branches}, opts) when is_atom(field) and is_map(branches) do
    branch_schemas =
      Enum.map(branches, fn {tag, branch} ->
        branch
        |> convert(opts)
        |> Map.update("properties", %{to_string(field) => %{"const" => tag}}, fn props ->
          Map.put(props, to_string(field), %{"const" => tag})
        end)
      end)

    %{
      "oneOf" => branch_schemas,
      "discriminator" => %{"propertyName" => to_string(field)}
    }
  end

  defp convert({:ref, name}, opts) when is_atom(name) do
    convert({:ref, {nil, name}}, opts)
  end

  defp convert({:ref, {mod, name}}, opts) when is_atom(mod) and is_atom(name) do
    def_key = ref_def_name(mod, name)
    register_def(def_key, mod, name, opts)
    %{"$ref" => "#/$defs/#{def_key}"}
  end

  defp convert({:custom, _} = node, opts), do: unsupported(node, "custom validator", opts)
  defp convert({:cond, _, _, _} = node, opts), do: unsupported(node, "conditional schema", opts)
  defp convert({:dependent, _} = node, opts), do: unsupported(node, "dependent schema", opts)
  defp convert({:dependent, _, _} = node, opts), do: unsupported(node, "dependent schema", opts)

  defp convert({:dependent, _, _, _} = node, opts),
    do: unsupported(node, "dependent schema", opts)

  defp convert({:dependent, _, _, _, _} = node, opts),
    do: unsupported(node, "dependent schema", opts)

  defp convert(schema, opts) when is_map(schema), do: encode_object(schema, opts)

  defp convert(other, opts), do: unsupported(other, "unknown type", opts)

  defp unsupported(type, reason, opts) do
    case Keyword.get(opts, :on_unsupported, :omit) do
      :raise -> raise UnsupportedTypeError, type: type, reason: reason
      _ -> %{}
    end
  end

  defp numeric_base(:integer), do: %{"type" => "integer"}
  defp numeric_base(:float), do: %{"type" => "number"}

  defp ref_def_name(nil, name), do: Atom.to_string(name)

  defp ref_def_name(mod, name) do
    "#{inspect(mod)}.#{Atom.to_string(name)}" |> String.replace(".", "_")
  end

  defp register_def(def_key, mod, name, opts) do
    defs = Process.get(:peri_json_schema_defs, %{})

    cond do
      Map.has_key?(defs, def_key) ->
        :ok

      is_nil(mod) ->
        Process.put(:peri_json_schema_defs, Map.put(defs, def_key, %{}))

      true ->
        Process.put(:peri_json_schema_defs, Map.put(defs, def_key, %{}))

        try do
          schema = mod.get_schema(name)
          body = if is_map(schema), do: encode_object(schema, opts), else: convert(schema, opts)
          updated = Map.put(Process.get(:peri_json_schema_defs, %{}), def_key, body)
          Process.put(:peri_json_schema_defs, updated)
        rescue
          _ -> :ok
        end
    end
  end

  defp apply_meta(schema, meta_opts, encoder_opts) do
    excluded = Keyword.get(encoder_opts, :exclude_meta_keys, [])

    Enum.reduce(meta_opts, schema, fn
      {key, value}, acc when key in @meta_keys ->
        if key in excluded, do: acc, else: put_meta(acc, key, value)

      _, acc ->
        acc
    end)
  end

  defp put_meta(schema, :example, value), do: Map.put(schema, "examples", List.wrap(value))
  defp put_meta(schema, :examples, value), do: Map.put(schema, "examples", List.wrap(value))

  defp put_meta(schema, key, value) do
    Map.put(schema, Map.get(@meta_key_renames, key, Atom.to_string(key)), value)
  end

  defp required?({:required, _}), do: true
  defp required?({:meta, type, _}), do: required?(type)
  defp required?(_), do: false
end
